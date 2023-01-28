require "tenderjit/util"
require "tenderjit/ir/operands"

class TenderJIT
  class IR
    NONE = Operands::None.new

    Instruction = Util::ClassGen.pos(:op, :arg1, :arg2, :out)

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
      Operands::InOut.new @instructions.length
    end

    def param idx
      Operands::Param.new(idx)
    end

    def uimm int
      Operands::UnsignedInt.new(int)
    end

    def imm int
      Operands::SignedInt.new(int)
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
      @labels[name] ||= Operands::Label.new(name)
    end

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
