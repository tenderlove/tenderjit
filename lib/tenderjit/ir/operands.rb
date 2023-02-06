require "tenderjit/util"

class TenderJIT
  class IR
    module Operands
      class None
        def register?; false; end
        def integer?; false; end
        def none?; true; end
        def ensure ra; self; end
        def free _, _, _; self; end
        def set_first_use _ ; end
        def set_last_use _ ; end
        def to_s; "NONE"; end
      end

      class Immediate < Util::ClassGen.pos(:value)
        def register? = false
        def immediate? = true
        def none? = false
        def integer? = false

        def ensure ra
          value
        end

        def set_last_use _ ; end
        def set_first_use _ ; end
        def free _, _, _; end

        def to_s; sprintf("IMM(%0#4x)", value); end
      end

      class UnsignedInt < Immediate; end
      class SignedInt < Immediate; end

      class VirtualRegister < Util::ClassGen.pos(:name, :physical_register, :last_use, :first_use)
        attr_writer :physical_register

        def integer? = false

        def initialize name, physical_register = nil, last_use = 0, first_use = nil
          super
        end

        def param? = false
        def immediate? = false
        def register? = true
        def none? = false

        def set_last_use i
          @last_use = i if @last_use < i
        end

        def set_first_use i
          @first_use ||= i
        end

        def used_at? i
          i > @first_use && i <= @last_use
        end

        def ensure ra
          ra.ensure self
        end

        def free ra, pr, i
          if physical_register && !used_after?(i)
            ra.free(pr)
            @physical_register = nil
            freeze
          end
        end

        def permanent
          set_last_use Float::INFINITY
          self
        end

        private

        def used_after? i
          @last_use > i
        end
      end

      class InOut < VirtualRegister
        def to_s; "TMP(#{name})"; end
      end

      class Param < VirtualRegister
        def param? = true
        def to_s; "PARAM(#{name})"; end
      end

      class Label < Util::ClassGen.pos(:name, :offset)
        def register? = false
        def integer? = false
        def immediate? = false

        def set_offset offset
          @offset = offset
          freeze
        end

        def unwrap_label; offset; end

        def ensure ra
          self
        end

        def free _, _, _; end
        def set_last_use _; end
        def set_first_use _; end

        def to_s; "LABEL(#{name})"; end
      end
    end
  end
end
