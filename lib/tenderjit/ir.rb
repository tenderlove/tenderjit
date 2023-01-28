require "tenderjit/util"

class TenderJIT
  class IR
    class None
      def register?; false; end
      def integer?; false; end
      def none?; true; end
      def ensure ra; self; end
      def free _, _, _; self; end
    end

    class Immediate < Util::ClassGen.pos(:value)
      def register? = false
      def immediate? = true
      def none? = false

      def ensure ra
        value
      end

      def free _, _, _; end
    end

    class UnsignedInt < Immediate; end
    class SignedInt < Immediate; end

    class VirtualRegister < Util::ClassGen.pos(:name, :physical_register, :last_use)
      attr_writer :physical_register

      def initialize name, physical_register = nil, last_use = 0
        super
      end

      def param? = false
      def immediate? = false
      def register? = true
      def none? = false

      def set_last_use i
        @last_use = i if @last_use < i
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

    def initialize
      @instructions = []
      @labels = {}
    end

    def each_instruction
      @instructions.each_with_index do |insn, i|
        yield insn, i
      end
    end

    def to_arm64
      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      cg.assemble ra, self
    end

    def var
      InOut.new @instructions.length
    end

    def param idx
      Param.new(idx)
    end

    def uimm int
      UnsignedInt.new(int)
    end

    def imm int
      SignedInt.new(int)
    end

    def write arg1, arg2
      push __method__, arg1, arg2, arg1
      arg1
    end

    def add arg1, arg2
      push __method__, arg1, arg2
    end

    def store reg, offset, value
      push __method__, reg, offset, value
      nil
    end

    def return arg1
      push __method__, arg1, NONE
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

    def nop
      push __method__, NONE, NONE, NONE
    end

    private

    def push name, a, b, out = self.var
      a.set_last_use @instructions.length if a.register?
      b.set_last_use @instructions.length if b.register?
      out.set_last_use @instructions.length if out.register?
      @instructions << Instruction.new(name, a, b, out)
      out
    end
  end
end
