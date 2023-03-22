require "tenderjit/error"
require "tenderjit/util"

class TenderJIT
  class IR
    module Operands
      class FreedBeforeUsed < TenderJIT::Error; end
      class FreedAfterHandled < TenderJIT::Error; end
      class UnknownState < TenderJIT::Error; end
      class UnusedOperand < TenderJIT::Error; end
      class ArgumentError < TenderJIT::Error; end
      class EnsureError < TenderJIT::Error; end
      class UnassignedRegister < TenderJIT::Error; end

      class None
        def register?; false; end
        def integer?; false; end
        def variable?; false; end
        def none?; true; end
        def label? = false
        def ensure _, _; self; end
        def free _, _; self; end
        def to_s; "NONE"; end
        def add_range _, _; end
        def clear_live_ranges!; end
        def set_from _; end
        def pr; self; end
        def definition= _; end
        def add_use _; end
        def unwrap; self; end
      end

      class Immediate < Util::ClassGen.pos(:value, :definition, :uses)
        attr_writer :definition

        def initialize value = nil, definition = nil, uses = []
          super
        end

        def unwrap
          value
        end

        def add_use insn
          @uses << insn
        end

        def remove_use insn
          @uses.delete insn
        end

        def register? = false
        def immediate? = true
        def none? = false
        def integer? = false
        def label? = false
        def variable?; false; end

        def ensure _, _
          value
        end

        def pr; value; end
        def free _, _; true end
        def add_range _, _; end
        def clear_live_ranges!; end
        def set_from _; end

        def to_s; sprintf("IMM(%0#4x)", value); end
      end

      class UnsignedInt < Immediate; end
      class SignedInt < Immediate; end

      class VirtualRegister < Util::ClassGen.pos(:name, :physical_register, :uses, :ranges)
        attr_writer :physical_register
        attr_accessor :definition, :live_range

        def integer?; false; end
        def label?; false; end
        def variable?; true; end
        def stack_pointer?; false; end

        def initialize name, physical_register = nil, uses = [], ranges = []
          super
          @definition = nil
          @live_range = self
        end

        def definitions
          [definition]
        end

        def combined?
          false
        end

        def add_use insn
          @uses << insn
        end

        def remove_use insn
          @uses.delete insn
        end

        def param?; false; end
        def immediate?; false; end
        def register?; true; end
        def none?; false; end

        ##
        # Unwrapped physical register
        def pr
          unless physical_register
            raise UnassignedRegister, "Virtual Register #{name} doesn't have a physical register"
          end
          physical_register.unwrap
        end

        def clear_live_ranges!
          @ranges.clear
        end

        def add_range from, to
          return if ranges.find { |_from, _| _from == from }
          ranges << [from, to]
          ranges.sort_by!(&:first)
        end

        def set_from from
          #if @ranges.empty?
          #  raise UnusedOperand, "Operand #{to_s} is unused"
          #end
          range = @ranges.find { |x, to|
            x <= from && to >= from
          }
          if range
            range[0] = from
          else
            ranges << [from, from]
          end
        end

        def first_use
          @ranges.first.first
        end

        def last_use
          @ranges.last.last
        end

        def used_at? i
          @ranges.any? { |(from, to)| i >= from && i <= to }
        end

        def usage_assigned?
          @ranges.any?
        end

        def ensure ra, i
          unless used_at?(i)
            raise EnsureError, "Register #{self} isn't live at instruction #{i}. Live at #{@ranges}"
          end

          ra.ensure self, i, last_use
        end

        def state_at i
          if i < first_use
            :unhandled
          else
            if used_at?(i)
              :active
            else
              if last_use < i
                :handled
              else
                :inactive
              end
            end
          end
        end

        def next_use from
          r = nil
          @ranges.each { |range|
            if range.first > from
              r = range
              break
            end
          }

          raise ArgumentError unless r
          r.first
        end

        def free ra, i
          case state_at(i)
          when :unhandled
            raise FreedBeforeUsed, "Freeing a register before it's used"
          when :active
            case state_at(i + 1)
            when :active
            when :handled  then ra.free self, physical_register
            when :inactive then ra.lend_until(physical_register, next_use(i + 1))
            when :unhandled then raise TenderJIT::Error
            end
          when :handled
            raise FreedAfterHandled, "Freeing a register after it's done"
          when :inactive
          else
            raise UnknownState, "Unknown state #{state_at(i).to_s}"
          end
        end
      end

      class InOut < VirtualRegister
        def to_s; "TMP(#{name})"; end

        ##
        # Spill this variable.  Returns the number of stores to the SP
        # it generated.
        def spill ir, counter
          case definition.op
          when :loadi
            if definition.bb.start == definition
              definition.bb.start = definition._next
            end

            definition.unlink
            uses.dup.each do |use|
              insn = ir.create :loadi, definition.arg1.unwrap, definition.arg2.unwrap
              if use.bb.start == use
                use.bb.start = insn
              end

              insn.bb = use.bb
              arg1 = use.arg1 == definition.out ? insn.out : use.arg1
              arg2 = use.arg2 == definition.out ? insn.out : use.arg2

              use.prev.append insn
              use.replace arg1, arg2
            end
            0
          when :load, :add, :sub
            # Insert a load before all uses
            insert_loads ir, counter

            # Insert a store after the definition
            insn = ir.create :store, definition.out, ir.sp, ir.uimm(counter)
            insn.bb = definition.bb
            definition.append insn
            1
          when :phi
            # Insert a load before all uses
            insert_loads ir, counter
            if definition.bb.start == definition
              definition.bb.start = definition._next
            end
            definition.unlink
            0
          else
            raise definition.op NotImplementedError
          end
        end

        def insert_loads ir, counter
          uses.dup.each do |use|
            next if use.phi?

            load_insn = ir.create :load, ir.sp, ir.uimm(counter)
            if use.bb.start == use
              use.bb.start = load_insn
            end
            use.prev.append load_insn
            load_insn.bb = use.bb

            arg1 = use.arg1 == self ? load_insn.out : use.arg1
            arg2 = use.arg2 == self ? load_insn.out : use.arg2
            use.replace arg1, arg2
          end

          uses.clear
        end

        def spill_cost
          if @uses.length == 1 && @definition._next == @uses.first
            Float::INFINITY
          else
            if @definition.op == :loadi
              -1
            else
              definition_cost + use_cost
            end
          end
        end

        private

        def use_cost
          @uses.group_by(&:bb).sum { |bb, uses|
            uses.length * load_cost(@definition.op) * bb.execution_frequency
          }
        end

        def definition_cost
          def_cost(@definition.op) + (store_cost(@definition.op) * @definition.bb.execution_frequency)
        end

        def load_cost op
          if op == :loadi
            0
          else
            2
          end
        end

        def store_cost op
          if op == :loadi
            0
          else
            1
          end
        end

        def def_cost op
          if op == :loadi
            1
          else
            2
          end
        end
      end

      class StackPointer < VirtualRegister
        def stack_pointer?; true; end
        def variable?; false; end
        def free _, _; false; end
        def to_s; "SP"; end
      end

      SP = StackPointer.new "SP"

      class Param < VirtualRegister
        def param?; true; end
        def variable?; false; end
        def to_s; "PARAM(#{name})"; end
        def free _, _; false; end
      end

      class Label < Util::ClassGen.pos(:name, :offset, :definition)
        attr_writer :definition

        def register? = false
        def integer? = false
        def immediate? = false
        def label? = true
        def variable?; false; end
        def clear_live_ranges!; end

        def set_offset offset
          @offset = offset
          freeze
        end

        def unwrap_label; offset; end

        def ensure _, _
          self
        end

        def pr; self; end

        def free _, _; true; end
        def set_from _; end

        def to_s; "LABEL(#{name})"; end
      end
    end
  end
end
