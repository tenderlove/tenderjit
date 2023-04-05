require "tenderjit/util"
require "tenderjit/ir/operands"
require "tenderjit/ir/instruction"
require "tenderjit/basic_block"
require "tenderjit/linked_list"
require "tenderjit/combined_live_range"

class TenderJIT
  class IR
    NONE = Operands::None.new

    attr_reader :counter

    def initialize
      @insn_head = LinkedList::Head.new
      @instructions = @insn_head
      @counter = 0
    end

    def current_instruction
      @instructions
    end

    def instructions; @insn_head; end

    def insert_at insn
      old, @instructions = @instructions, insn
      yield self
    ensure
      @instructions = old
    end

    def each_instruction
      @insn_head.each_with_index do |insn, i|
        yield insn, i
      end
    end

    def basic_blocks
      BasicBlock.build @insn_head, self, true
    end

    def insert_jump node, label
      insert_at(node) { jmp label }
      node._next
    end

    def assemble
      basic_blocks.assemble
    end

    def assemble_patch
      basic_blocks.assemble_patch
    end

    def write_to buffer
      assemble.write_to buffer
    end

    def loadsp
      sp = Operands::StackPointer.new(@counter)
      @counter += 1
      _push __method__, NONE, NONE, sp
    end

    def var
      op = Operands::InOut.new(@counter)
      @counter += 1
      op
    end

    def uimm int, width = nil
      Operands::UnsignedInt.new(int, width)
    end

    def imm int, width = nil
      Operands::SignedInt.new(int, width)
    end

    def push arg1, arg2 = NONE
      _push __method__, arg1, arg2, NONE
    end

    def pop
      _push __method__, NONE, NONE, NONE
    end

    def loadi val
      val = imm(val) if val.integer?
      raise unless val.immediate?

      _push __method__, val, NONE
    end

    def storei imm, arg
      _push __method__, self.imm(imm), NONE, arg
    end

    def shr arg1, arg2
      _push __method__, arg1, arg2
    end

    def shl arg1, arg2
      _push __method__, arg1, arg2
    end

    def set_param arg1
      _push __method__, arg1, NONE
    end

    def stack_alloc arg1
      _push __method__, arg1, NONE, NONE
    end

    def save_params arg1
      _push __method__, arg1, NONE, NONE
    end

    def restore_params arg1
      _push __method__, arg1, NONE, NONE
    end

    def stack_delloc arg1
      _push __method__, arg1, NONE, NONE
    end

    def patch_location &blk
      insn = new_insn PatchLocation, :patch_location, NONE, NONE, NONE
      insn.block = blk
      @instructions = @instructions.append insn
      insn.out
    end

    def call location, params
      insn = new_insn Call, :call, location, NONE, retvar
      raise ArgumentError if params.any?(&:integer?)
      raise ArgumentError unless params.all?(&:register?)

      insn.params = params
      @instructions = @instructions.append insn
      insn.out
    end

    def copy reg
      raise ArgumentError if reg.integer?
      raise ArgumentError unless reg.register?
      _push __method__, reg, NONE
    end

    def add arg1, arg2
      if arg2.integer? && arg2 == 0
        return arg1
      end

      _push __method__, arg1, arg2
    end

    def mod arg1, arg2
      _push __method__, arg1, arg2
    end

    def tbz reg, bit_no, dest
      raise ArgumentError unless bit_no.integer?
      _push __method__, reg, bit_no, dest
      nil
    end

    def tbnz reg, bit_no, dest
      raise ArgumentError unless bit_no.integer?
      _push __method__, reg, bit_no, dest
      nil
    end

    def sub arg1, arg2
      raise ArgumentError, "First parameter must be a register" if arg1.integer?
      _push __method__, arg1, arg2
    end

    def or arg1, arg2
      raise ArgumentError, "First parameter must be a register" unless arg1.register?
      arg2 = uimm(arg2) if arg2.integer?

      _push __method__, arg1, arg2
    end

    def dec arg1, arg2
      raise ArgumentError, "First parameter must be a register" if arg1.integer?
      _push __method__, arg1, arg2, NONE
    end

    def store value, reg, offset
      offset = uimm(offset) if offset.integer?
      raise ArgumentError unless offset.immediate?
      _push __method__, value, reg, offset
      nil
    end

    def ret arg1
      _push __method__, arg1, NONE, NONE
      nil
    end

    class Phi < IR::Instruction
      def inputs
        [arg1, arg2]
      end

      def used_variables
        []
      end

      def combined_range
        CombinedLiveRange.new(arg1, arg2, out)
      end

      def phi?; true; end
    end

    def phi arg1, arg2
      out = var
      insn = new_insn(Phi, :phi, arg1, arg2, out)
      arg1.live_range = arg2.live_range = out.live_range = insn.combined_range
      @instructions = @instructions.append insn
      out
    end

    def loadp num
      raise ArgumentError unless num.integer?
      _push __method__, NONE, NONE, param(num)
    end

    def load arg1, arg2
      _push __method__, arg1, arg2
    end

    def cmp arg1, arg2
      _push __method__, arg1, arg2, NONE
      nil
    end

    def label name
      Operands::Label.new(name)
    end

    def csel_eq arg1, arg2
      raise ArgumentError if arg1.integer? || arg2.integer?
      _push __method__, arg1, arg2
    end

    def csel_lt arg1, arg2
      raise ArgumentError if arg1.integer? || arg2.integer?
      _push __method__, arg1, arg2
    end

    def csel_gt arg1, arg2
      raise ArgumentError if arg1.integer? || arg2.integer?
      _push __method__, arg1, arg2
    end

    def jz arg1, dest
      _push __method__, arg1, NONE, dest
      nil
    end

    def jnz arg1, dest
      _push __method__, arg1, NONE, dest
      nil
    end

    def jle arg1, arg2, dest
      _push __method__, arg1, arg2, dest
      nil
    end

    def jgt arg1, arg2, dest
      _push __method__, arg1, arg2, dest
      nil
    end

    def jne arg1, arg2, dest
      _push __method__, arg1, arg2, dest
      nil
    end

    def je arg1, arg2, dest
      _push __method__, arg1, arg2, dest
      nil
    end

    def jmp location
      _push __method__, NONE, NONE, location
      nil
    end

    def jo location
      _push __method__, NONE, NONE, location
      nil
    end

    def brk
      _push __method__, NONE, NONE, NONE
      nil
    end

    def neg arg1
      _push __method__, arg1, NONE
    end

    def and arg1, arg2
      arg2 = uimm(arg2) if arg2.integer?

      _push __method__, arg1, arg2
    end

    def mul arg1, arg2
      raise ArgumentError if arg1.integer? || arg2.integer?
      raise ArgumentError if arg1.immediate? || arg2.immediate?

      _push __method__, arg1, arg2
    end

    ##
    # Jump if not false or Qnil
    def jnfalse arg1, dest
      _push __method__, arg1, NONE, dest
      nil
    end

    ##
    # Jump if false or Qnil
    def jfalse arg1, dest
      _push __method__, arg1, NONE, dest
      nil
    end

    def put_label name
      raise unless name.is_a?(Operands::Label)
      _push __method__, NONE, NONE, name
      nil
    end

    def nop
      _push __method__, NONE, NONE, NONE
    end

    def create name, a, b, out = self.var
      new_insn Instruction, name, a, b, out
    end

    private

    def _push name, a, b, out = self.var
      @instructions = @instructions.append new_insn(Instruction, name, a, b, out)
      out
    end

    def new_insn klass, name, a, b, out
      a = uimm(a) if a.integer?
      b = uimm(b) if b.integer?
      raise ArgumentError, "labels should only be outputs" if a.label? || b.label?

      insn = klass.new name, a, b, out
      a.add_use insn
      b.add_use insn
      out.definition = insn
      insn
    end

    def param idx
      op = Operands::Param.new(@counter, idx)
      @counter += 1
      op
    end

    def retvar
      op = Operands::RetVar.new(@counter)
      @counter += 1
      op
    end
  end
end
