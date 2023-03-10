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
      end

      class Immediate < Util::ClassGen.pos(:value)
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

      class VirtualRegister < Util::ClassGen.pos(:name, :physical_register, :ranges)
        attr_writer :physical_register

        def integer?; false; end
        def label?; false; end
        def variable?; true; end
        def stack_pointer?; false; end

        def initialize name, physical_register = nil, ranges = []
          super
        end

        def param?; false; end
        def immediate?; false; end
        def register?; true; end
        def none?; false; end

        ##
        # Unwrapped physical register
        def pr
          physical_register.unwrap
        end

        def clear_live_ranges!
          @physical_register = nil
          @ranges.clear
        end

        def add_range from, to
          unless ranges.last && ranges.last.first == from
            ranges << [from, to]
            ranges.sort_by! { |from, to| from }.reverse!
          end
        end

        def set_from from
          if @ranges.empty?
            raise UnusedOperand, "Operand #{to_s} is unused"
          end
          @ranges.last[0] = from
        end

        def first_use
          @ranges.last.first
        end

        def last_use
          @ranges.first.last
        end

        def used_at? i
          @ranges.any? { |(from, to)| i >= from && i <= to }
        end

        def usage_assigned?
          @ranges.any?
        end

        def ensure ra, i
          raise TenderJIT::Error unless used_at?(i)

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
          @ranges.reverse_each { |range|
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

      class Label < Util::ClassGen.pos(:name, :offset)
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
