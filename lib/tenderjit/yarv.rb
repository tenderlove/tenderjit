require "tenderjit/util"
require "tenderjit/linked_list"
require "tenderjit/basic_block"

class TenderJIT
  class YARV
    class Instruction < Util::ClassGen.pos(:op, :pc, :insn, :opnds, :number)
      include LinkedList::Element

      attr_writer :number

      def put_label?
        op == :put_label
      end

      def label
        raise unless put_label?
        insn
      end

      def jump?
        op == :leave || op == :branchunless || op == :branchif || op == :jump
      end

      def has_jump_target?
        op == :branchunless || op == :branchif || op == :jump
      end

      def unconditional_jump?
        op == :leave || op == :jump
      end

      def used_variables
        return unless op == :getlocal
        [opnds]
      end

      def set_variable
        return unless op == :setlocal
        opnds
      end

      def target_label
        out = opnds.first
        return out if out.label?
        raise "not a jump instruction"
      end

      def to_s
        "#{number} #{op}\t#{opnds.map(&:to_s).join("\t")}"
      end
    end

    class Label < Util::ClassGen.pos(:name)
      def label?; true; end

      def to_s
        "LABEL(#{name})"
      end
    end

    def self.dump_insns insns, ansi: true
      insns.map { |insn| insn.to_s }.join("\\l") + "\\l"
    end

    def self.vars set
      set.to_a.inspect
    end

    def initialize
      @insn_head = LinkedList::Head.new
      @instructions = @insn_head
      @label_map = {}
    end

    def basic_blocks
      BasicBlock.build @insn_head, self, false
    end

    def cfg
      CFG.new basic_blocks, YARV
    end

    def insert_jump node, label
      jump = new_insn :jump, node.pc, Object.new, [label]
      node.insert jump
    end

    def peephole_optimize!
      @insn_head.each do |insn|
        # putobject
        # pop
        if insn.op == :putobject && insn._next.op == :pop
          insn._next.unlink
          insn.unlink
        end

        if insn.op == :jump && !insn.prev.head? && insn.prev.op == :jump
          insn.prev.unlink
        end
      end
    end

    def handle pc, insn, operands
      if label = @label_map[pc]
        put_label pc, label
      end
      send insn.name, pc, insn, operands
    end

    def getlocal_WC_0 pc, insn, ops
      getlocal pc, insn, [ops[0], 0]
    end

    def getlocal pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def opt_eq pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def setlocal_WC_0 pc, insn, ops
      setlocal pc, insn, [ops[0], 0]
    end

    def setlocal pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def opt_plus pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def opt_minus pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def leave pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def putobject pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def putobject_INT2FIX_1_ pc, insn, ops
      putobject pc, insn, [1]
    end

    def putnil pc, insn, ops
      putobject pc, insn, [nil]
    end

    def pop pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def opt_lt pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def opt_gt pc, insn, ops
      add_insn __method__, pc, insn, ops
    end

    def branchunless pc, insn, ops
      offset = ops.first

      # offset is PC + dest
      dest_pc = pc + offset + 2 # branchunless is 2 wide

      label = insert_label_at_pc pc, dest_pc

      add_insn __method__, pc, insn, [label]
    end

    def branchif pc, insn, ops
      offset = ops.first

      # offset is PC + dest
      dest_pc = pc + offset + 2 # branchunless is 2 wide

      label = insert_label_at_pc pc, dest_pc

      add_insn __method__, pc, insn, [label]
    end

    def put_label pc, label
      add_insn __method__, pc, label, [label]
    end

    def jump pc, insn, ops
      offset = ops.first

      # offset is PC + dest
      dest_pc = pc + offset + 2 # branchunless is 2 wide

      label = insert_label_at_pc pc, dest_pc

      add_insn __method__, pc, insn, [label]
    end

    private

    def insert_label_at_pc current_pc, dest_pc
      label = @label_map[dest_pc] ||= Label.new(dest_pc)

      if dest_pc < current_pc
        insn = @instructions

        while insn.pc > dest_pc
          insn = insn.prev
        end

        before = insn.prev

        put_label = Instruction.new :put_label, insn.pc, label, [label]
        put_label.append insn
        before.append put_label
      end

      label
    end

    def add_insn name, pc, insn, opnds
      insn = new_insn name, pc, insn, opnds
      @instructions = @instructions.append insn
    end

    def new_insn name, pc, insn, opnds
      Instruction.new name, pc, insn, opnds
    end
  end
end
