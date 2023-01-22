require "tenderjit/util"

class TenderJIT
  class IR
    class None
      def register?; false; end
      def ensure ra; self; end
      def free _, _, _; self; end
    end

    class Immediate < Util::ClassGen.pos(:value)
      def register? = false
      def immediate? = true

      def ensure ra
        value
      end

      def free _, _, _; end
    end

    class UnsignedInt < Immediate; end

    class VirtualRegister < Util::ClassGen.pos(:name, :physical_register, :next_uses)
      attr_writer :physical_register

      def initialize name, physical_register = nil, next_uses = []
        super
      end

      def param? = false
      def immediate? = false
      def register? = true

      def used_after? i
        next_uses.any? { |n| n > i }
      end

      def used_at i
        @next_uses << i
      end

      def ensure ra
        ra.ensure self
      end

      def free ra, pr, i
        ra.free(pr) unless used_after?(i)
      end
    end

    class InOut < VirtualRegister; end

    class Param < VirtualRegister
      def param? = true
    end

    Instruction = Util::ClassGen.pos(:op, :arg1, :arg2, :out)

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
    end

    attr_reader :instructions

    def initialize
      @instructions = []
      @labels = {}
    end

    def to_arm64
      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      cg.assemble ra, self
    end

    def param idx
      Param.new(idx)
    end

    def uimm int
      UnsignedInt.new(int)
    end

    def write arg1, arg2
      push __method__, arg1, arg2
    end

    def add arg1, arg2
      push __method__, arg1, arg2
    end

    def return arg1
      push __method__, arg1, arg1
    end

    def load arg1, arg2
      push __method__, arg1, arg2
    end

    def label name
      @labels[name] ||= Label.new(name)
    end

    NONE = None.new

    def jle arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def jmp location
      push __method__, location, NONE
      nil
    end

    def brk
      push __method__, NONE, NONE
    end

    def neg arg1
      push __method__, arg1, NONE
    end

    def and arg1, arg2
      push __method__, arg1, arg2
    end

    def put_label name
      push __method__, @labels.fetch(name), NONE
    end

    private

    def push name, a, b, out = InOut.new(@instructions.length)
      a.used_at @instructions.length if a.register?
      b.used_at @instructions.length if b.register?
      @instructions << Instruction.new(name, a, b, out)
      out
    end
  end
end
