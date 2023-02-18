require "tenderjit/util"
require "tenderjit/ir/operands"
require "tenderjit/ir/instruction"
require "tenderjit/ir/basic_block"

class TenderJIT
  class IR
    NONE = Operands::None.new

    def initialize
      @insn_head = Head.new
      @instructions = @insn_head
      @virtual_register_name = 0
    end

    def instructions; @insn_head; end

    def dump_usage highlight_insn = nil
      self.class.dump_insns instructions, highlight_insn
    end

    def self.dump_insns instructions, highlight_insn: nil, ansi: true
      virt_regs = instructions.flat_map { |insn|
        [insn.arg1, insn.arg2, insn.out]
      }.select(&:register?).uniq
      params, regs = virt_regs.partition(&:param?)
      regs = regs.select(&:usage_assigned?)
      maxwidth = [0, 0, 0, 0]
      instructions.each do |insn|
        maxwidth[0] = insn.op.to_s.length if insn.op.to_s.length > maxwidth[0]
        maxwidth[1] = insn.arg1.to_s.length if insn.arg1.to_s.length > maxwidth[1]
        maxwidth[2] = insn.arg2.to_s.length if insn.arg2.to_s.length > maxwidth[2]
        maxwidth[3] = insn.out.to_s.length if insn.out.to_s.length > maxwidth[3]
      end

      sorted_regs = regs.sort_by(&:name)
      first = sorted_regs.first
      buff = "".dup
      buff << "   " if highlight_insn
      buff << " " * (maxwidth[0] + 1)
      buff << "IN1".ljust(maxwidth[1] + 1)
      buff << "IN2".ljust(maxwidth[2] + 1)
      buff << "OUT".ljust(maxwidth[3] + 1)
      buff << sorted_regs.map { _1.name.to_s.ljust(3) }.join + "\n"
      insn_strs = instructions.map.with_index do |insn, j|
        start = ""

        if highlight_insn
          if j == highlight_insn
            bold = 1
            start += "-> "
          else
            start += "   "
          end
        end

        if ansi
          if j.even?
            if j == highlight_insn
              start += "\033[30;1m"
            else
              start += "\033[30;0;0m"
            end
          else
            if j == highlight_insn
              start += "\033[30;1;107m"
            else
              start += "\033[30;0;107m"
            end
          end
        end

        start + insn.op.to_s.ljust(maxwidth[0] + 1) +
          "#{insn.arg1.to_s}".ljust(maxwidth[1] + 1) +
          "#{insn.arg2.to_s}".ljust(maxwidth[2] + 1) +
          "#{insn.out.to_s}".ljust(maxwidth[3] + 1) +
          sorted_regs.map { |r|
            r.first_use == j ? "O  " : r.used_at?(j) ? "X  " : "   "
          }.join + (ansi ? "\033[0m" : "")
      end
      insn_strs.each { buff << _1 + "\n" }
      buff
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

    def basic_blocks
      bbs = []
      insn = @insn_head._next
      i = 0
      wants_label = []
      has_label = {}

      while insn
        start = finish = insn
        while finish._next && !finish._next.put_label?
          finish = finish._next
          break if finish.jump?
        end

        jumps_back = if finish.jump? && finish.has_jump_target?
          has_label.key?(finish.target_label)
        else
          false
        end

        bb = BasicBlock.new(i, start, finish, jumps_back)

        wants_label << bb if bb.has_jump_target?

        has_label[bb.label] = bb if bb.labeled_entry?

        if bbs.last && bbs.last.falls_through?
          bbs.last.fall_through = bb
          bb.predecessors << bbs.last
        end

        bbs << bb
        i += 1
        insn = finish._next
      end

      while bb = wants_label.pop
        jump_target = has_label.fetch(bb.jump_target_label)
        bb.jump_target = jump_target
        jump_target.predecessors << bb
      end

      bbs
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
      push __method__, arg1, arg2, arg1
      arg1
    end

    def add arg1, arg2
      push __method__, arg1, arg2
    end

    def tbz reg, bit_no, dest
      raise ArgumentError unless bit_no.integer?
      push __method__, reg, bit_no, dest
      nil
    end

    def tbnz reg, bit_no, dest
      raise ArgumentError unless bit_no.integer?
      push __method__, reg, bit_no, dest
      nil
    end

    def sub arg1, arg2
      raise ArgumentError, "First parameter must be a register" if arg1.integer?
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

    def cmp arg1, arg2
      push __method__, arg1, arg2, NONE
      nil
    end

    def label name
      Operands::Label.new(name)
    end

    def csel_lt arg1, arg2
      raise ArgumentError if arg1.integer? || arg2.integer?
      push __method__, arg1, arg2
    end

    def jle arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def jne arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def je arg1, arg2, dest
      push __method__, arg1, arg2, dest
      nil
    end

    def jmp location
      push __method__, NONE, NONE, location
      nil
    end

    def jo location
      push __method__, NONE, NONE, location
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
      raise unless name.is_a?(Operands::Label)
      push __method__, NONE, NONE, name
      nil
    end

    def nop
      push __method__, NONE, NONE, NONE
    end

    private

    def push name, a, b, out = self.var
      a = uimm(a) if a.integer?
      b = uimm(b) if b.integer?
      raise if a.label? || b.label?

      @instructions = @instructions.append Instruction.new(name, a, b, out)
      out
    end
  end
end
