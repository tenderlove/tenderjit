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

    def instructions; @insn_head; end

    def dump_usage
      virt_regs = instructions.flat_map { |insn|
        [insn.arg1, insn.arg2, insn.out]
      }.select(&:register?).uniq
      params, regs = virt_regs.partition(&:param?)
      maxwidth = [0, 0, 0, 0]
      instructions.each do |insn|
        maxwidth[0] = insn.op.to_s.length if insn.op.to_s.length > maxwidth[0]
        maxwidth[1] = insn.arg1.to_s.length if insn.arg1.to_s.length > maxwidth[1]
        maxwidth[2] = insn.arg2.to_s.length if insn.arg2.to_s.length > maxwidth[2]
        maxwidth[3] = insn.out.to_s.length if insn.out.to_s.length > maxwidth[3]
      end

      sorted_regs = regs.sort_by(&:name)
      first = sorted_regs.first
      print " " * (maxwidth[0] + 1)
      print "IN1".ljust(maxwidth[1] + 1)
      print "IN2".ljust(maxwidth[2] + 1)
      print "OUT".ljust(maxwidth[3] + 1)
      puts sorted_regs.map { _1.name.to_s.ljust(3) }.join
      insn_strs = instructions.map.with_index do |insn, j|
        insn.op.to_s.ljust(maxwidth[0] + 1) +
          "#{insn.arg1.to_s}".ljust(maxwidth[1] + 1) +
          "#{insn.arg2.to_s}".ljust(maxwidth[2] + 1) +
          "#{insn.out.to_s}".ljust(maxwidth[3] + 1) +
          sorted_regs.map { |r|
            r.first_use == j ? "O  " : r.used_at?(j) ? "X  " : "   "
          }.join
      end
      insn_strs.each { puts _1 }
    end

    def each_instruction
      @insn_head.each_with_index do |insn, i|
        insn.arg1.set_last_use i
        insn.arg2.set_last_use i
        insn.out.set_first_use i
      end

      @insn_head.each_with_index do |insn, i|
        yield insn, i
      end
    end

    def insn_str insn
      "#{insn.op} #{insn.arg1.to_s}, #{insn.arg2.to_s}, #{insn.out.to_s}"
    end

    def to_arm64
      require "tenderjit/arm64/register_allocator"
      require "tenderjit/arm64/code_gen"

      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      ra.assemble self, cg
    end

    def to_x86_64
      require "tenderjit/x86_64/register_allocator"
      require "tenderjit/x86_64/code_gen"

      ra = X86_64::RegisterAllocator.new
      cg = X86_64::CodeGen.new

      ra.assemble self, cg
    end

    def to_binary
      if Util::PLATFORM == :arm64
        to_arm64
      else
        to_x86_64
      end
    end

    def write_to buffer
      to_binary.write_to buffer
    end

    def var
      @virtual_register_name += 1
      Operands::InOut.new(@virtual_register_name)
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

    def set_param arg1
      push __method__, arg1, NONE, NONE
    end

    def call location, arity
      push __method__, location, arity, param(0)
    end

    def write arg1, arg2
      push __method__, NONE, arg2, arg1
      arg1
    end

    def add arg1, arg2
      push __method__, arg1, arg2
    end

    def sub arg1, arg2
      push __method__, arg1, arg2
    end

    def store value, reg, offset
      offset = uimm(offset) if offset.integer?
      raise ArgumentError unless offset.immediate?
      push __method__, value, reg, offset
      nil
    end

    def return arg1
      push __method__, arg1, NONE, NONE
      nil
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

    def jne arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def tbnz arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def je arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def jmp location
      push __method__, location, NONE, NONE
      nil
    end

    def brk
      push __method__, NONE, NONE, NONE
      nil
    end

    def neg arg1
      push __method__, arg1, NONE
    end

    def and arg1, arg2
      push __method__, arg1, arg2
    end

    def put_label name
      push __method__, @labels.fetch(name), NONE, NONE
      nil
    end

    def nop
      push __method__, NONE, NONE, NONE
    end

    private

    def push name, a, b, out = self.var
      a = uimm(a) if a.integer?
      b = uimm(b) if b.integer?

      @instructions = @instructions.append Instruction.new(name, a, b, out)
      out
    end
  end
end
