require "tenderjit/util"
require "tenderjit/ir/operands"
require "tenderjit/ir/instruction"
require "tenderjit/basic_block"
require "tenderjit/cfg"
require "tenderjit/linked_list"

class TenderJIT
  class IR
    NONE = Operands::None.new

    attr_reader :counter

    def initialize insn = LinkedList::Head.new, counter = 0
      @insn_head = insn
      @instructions = @insn_head
      @counter = counter
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

    def dump_usage highlight_insn = nil
      self.class.dump_insns instructions, highlight_insn: highlight_insn
    end

    def vars set
      set.map(&:to_s).join(", ")
    end

    def dump_insns instructions, highlight_insn: nil, ansi: true
      self.class.dump_insns instructions, highlight_insn: highlight_insn, ansi: ansi
    end

    def self.dump_insns instructions, highlight_insn: nil, ansi: true
      virt_regs = instructions.flat_map { |insn|
        insn.registers
      }.uniq
      regs = virt_regs.select(&:variable?)
      regs = regs.select(&:usage_assigned?)

      physical_regs = regs.map(&:physical_register).compact.map(&:unwrap).uniq.sort_by(&:to_i)

      phys_reg_names = physical_regs.map { |x| "R#{x.to_i}" }
      phys_reg_name_max_width = 3

      if phys_reg_names.any?
        phys_reg_name_max_width = phys_reg_names.sort_by(&:length).last.length + 1
      end

      maxwidth = [0, 0, 0, 0]
      num = 0
      instructions.each do |insn|
        maxwidth[0] = insn.op.to_s.length if insn.op.to_s.length > maxwidth[0]
        maxwidth[1] = insn.arg1.to_s.length if insn.arg1.to_s.length > maxwidth[1]
        maxwidth[2] = insn.arg2.to_s.length if insn.arg2.to_s.length > maxwidth[2]
        maxwidth[3] = insn.out.to_s.length if insn.out.to_s.length > maxwidth[3]
        num = insn.number
      end

      num_width = num.to_s.length
      sorted_regs = regs.sort_by(&:name)
      buff = "".dup
      buff << "   "
      buff << " " * (maxwidth[0] + num_width + 2)
      buff << "OUT".ljust(maxwidth[3] + 1)
      buff << "IN1".ljust(maxwidth[1] + 1)
      buff << "IN2".ljust(maxwidth[2] + 1)

      buff << sorted_regs.map { _1.name.to_s.ljust(phys_reg_name_max_width) }.join

      buff << "\n"

      insn_strs = instructions.map.with_index do |insn, j|
        start = ""

        if highlight_insn
          if insn.number == highlight_insn
            start += "-> "
          else
            start += "   "
          end
        else
          start += "   "
        end

        if ansi
          if j.even?
            if insn.number == highlight_insn
              start += "\033[30;1m"
            else
              start += "\033[30;0;0m"
            end
          else
            if insn.number == highlight_insn
              start += "\033[30;1;107m"
            else
              start += "\033[30;0;107m"
            end
          end
        end

        start + insn.number.to_s.ljust(num_width) + " " + insn.op.to_s.ljust(maxwidth[0] + 1) +
          "#{insn.out.to_s}".ljust(maxwidth[3] + 1) +
          "#{insn.arg1.to_s}".ljust(maxwidth[1] + 1) +
          "#{insn.arg2.to_s}".ljust(maxwidth[2] + 1) +
          sorted_regs.map { |r|
            label = if r.physical_register
                      if r.used_at?(insn.number)
                        "R#{r.physical_register.unwrap.to_i}"
                      else
                        " "
                      end
                    else
                      if r.first_use == insn.number
                        "A"
                      else
                        if r.last_use == insn.number
                          "V"
                        else
                          if r.used_at?(insn.number)
                            "X"
                          else
                            " "
                          end
                        end
                      end
                    end
            label.ljust(phys_reg_name_max_width)
          }.join + (ansi ? "\033[0m" : "")
      end
      insn_strs.each { buff << _1 + "\n" }
      buff
    end

    def set_last_use
      @insn_head.each_with_index do |insn, i|
        insn.used_at i
      end
    end

    def each_instruction
      @insn_head.each_with_index do |insn, i|
        yield insn, i
      end
    end

    def basic_blocks
      BasicBlock.build @insn_head, self, true
    end

    def cfg
      CFG.new basic_blocks, self
    end

    def insert_jump node, label
      node.insert new_insn :jmp, NONE, NONE, label
    end

    def insn_str insn
      "#{insn.op} #{insn.arg1.to_s}, #{insn.arg2.to_s}, #{insn.out.to_s}"
    end

    def to_arm64
      require "tenderjit/arm64/register_allocator"
      require "tenderjit/arm64/code_gen"

      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      ra.assemble cfg, cg
    end

    def to_x86_64
      require "tenderjit/x86_64/register_allocator"
      require "tenderjit/x86_64/code_gen"

      ra = X86_64::RegisterAllocator.new
      cg = X86_64::CodeGen.new

      ra.assemble self, cg
    end

    def assemble
      x = cfg
      m = x.assemble
      if $DEBUG
        File.binwrite("ir_cfg.dot", cfg.to_dot)
      end
      m
    end

    def write_to buffer
      assemble.write_to buffer
    end

    def sp
      Operands::SP
    end

    def var
      @counter += 1
      Operands::InOut.new(@counter)
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

    def loadi imm
      push __method__, self.imm(imm), NONE
    end

    def set_param arg1
      push __method__, arg1, NONE, NONE
    end

    def call location, arity
      push __method__, location, arity, param(0)
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

    class Phi < IR::Instruction
      def initialize arg1, arg2, out
        super(:phi, arg1, arg2, out)
      end

      def inputs
        [arg1, arg2]
      end

      def used_variables
        []
      end

      def phi?; true; end
    end

    def phi arg1, arg2
      out = var
      @instructions = @instructions.append Phi.new(arg1, arg2, out)
      out
    end

    alias :ret :return

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

    def csel_gt arg1, arg2
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

    ##
    # Jump if not false or Qnil
    def jnfalse arg1, dest
      push __method__, arg1, NONE, dest
      nil
    end

    ##
    # Jump if false or Qnil
    def jfalse arg1, dest
      push __method__, arg1, NONE, dest
      nil
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

      @instructions = @instructions.append new_insn(name, a, b, out)
      out
    end

    def new_insn name, a, b, out
      Instruction.new name, a, b, out
    end
  end
end
