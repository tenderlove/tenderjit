require "tenderjit/util"
require "tenderjit/ir/operands"

class TenderJIT
  class IR
    NONE = Operands::None.new

    class Head < Util::ClassGen.pos(:_next, :prev)
      include Enumerable

      def append node
        @_next = node
        node.prev = self
        node
      end

      def each
        node = @_next
        while node
          yield node
          node = node._next
        end
      end
    end

    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out, :_next, :prev)
      attr_writer :prev

      def append node
        @_next = node
        node.prev = self
        node
      end
    end

    def initialize
      @insn_head = Head.new
      @instructions = @insn_head
      @labels = {}
      @virtual_register_name = 0
    end

    def each_instruction
      @insn_head.each_with_index do |insn, i|
        insn.arg1.set_last_use i
        insn.arg2.set_last_use i
        insn.out.set_last_use i
      end

      @insn_head.each_with_index do |insn, i|
        yield insn, i
      end
    end

    def to_arm64
      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      cg.assemble ra, self
    end

    def var
      Operands::InOut.new(@virtual_register_name += 1)
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
      @instructions = @instructions.append Instruction.new(name, a, b, out)
      out
    end
  end
end
