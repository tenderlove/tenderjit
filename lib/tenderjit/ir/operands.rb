# frozen_string_literal: true

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
        def label?; false; end
        def to_s; "NONE"; end
        def pr; self; end
        def definition= _; end
        def add_use _; end
        def unwrap; self; end
        def remove_use _; end
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

        def pr; value; end

        def to_s; sprintf("IMM(%0#4x)", value); end
      end

      class UnsignedInt < Immediate
        attr_reader :bits

        def initialize value, bits
          super(value)
          @bits = bits
        end
      end

      class SignedInt < Immediate
        attr_reader :bits

        def initialize value, bits
          super(value)
          @bits = bits
        end
      end

      class VirtualRegister < Util::ClassGen.pos(:name, :physical_register, :uses, :ranges)
        attr_writer :physical_register
        attr_accessor :definition, :live_range

        def integer?; false; end
        def label?; false; end
        def variable?; true; end
        def stack_pointer?; false; end
        def rclass; :general; end

        def to_s; "#{varname}(#{name})"; end

        def varname; "TMP"; end

        def initialize name, physical_register = nil, uses = [], ranges = []
          super
          @definition = nil
          @live_range = self
        end

        def definitions
          [definition]
        end

        def hash
          name.hash
        end

        def eql? other
          name == other.name
        end

        def combined?
          false
        end

        def copy
          self.class.new(name, physical_register)
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
            raise UnassignedRegister, "Virtual Register #{to_s} doesn't have a physical register"
          end
          physical_register
        end
      end

      class InOut < VirtualRegister
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
        def sp?; true; end
        def variable?; true; end
        def varname; "SP"; end
        def rclass; :sp; end
      end

      class RetVar < VirtualRegister
        def variable?; true; end
        def varname; "RETV"; end
        def rclass; :ret; end

        def spill_cost; Float::INFINITY; end
      end

      class Param < VirtualRegister
        attr_reader :number

        def initialize counter, num
          super(counter)
          @number = num
        end

        def param?; true; end
        def variable?; true; end
        def varname; "PARAM_#{@number}"; end
        def rclass; :param; end

        def spill_cost; 2; end
      end

      class Label < Util::ClassGen.pos(:name, :offset, :definition)
        attr_writer :definition

        def register? = false
        def integer? = false
        def immediate? = false
        def label? = true
        def variable?; false; end

        def set_offset offset
          @offset = offset
          freeze
        end

        def unwrap_label; offset; end

        def pr; self; end

        def to_s; "LABEL(#{name})"; end
      end
    end
  end
end
