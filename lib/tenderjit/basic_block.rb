require "tenderjit/util"
require "tenderjit/bitmatrix"
require "tenderjit/adjacency_list"

class TenderJIT
  class BasicBlock < Util::ClassGen.pos(:name, :head, :start, :finish)
    autoload :Printer, "tenderjit/basic_block/printer"

    attr_writer :start, :finish

    def self.build insn_head, ir, ssa
      head = last_bb = Head.new insn_head, ssa, ir
      insn = insn_head._next
      i = 0
      wants_label = []
      has_label = {}
      all_bbs = []

      while insn
        start = finish = insn

        bb = BasicBlock.new(i, head, start, nil)
        bb.add_instruction finish

        while finish._next
          break if finish.jump? || finish.return? || finish.call?
          break if finish._next.put_label?
          _next = finish._next
          bb.add_phi finish if finish.phi?
          finish = _next
          bb.add_instruction finish
        end

        all_bbs << bb

        has_label[bb.label] = bb if bb.labeled_entry?

        wants_label << bb if bb.has_jump_target?

        if last_bb.falls_through?
          last_bb.add_edge bb
          bb.predecessors << last_bb
        end

        unless last_bb.jumps? || last_bb.returns? || last_bb.calls?
          last_bb.add_jump ir, bb.label
        end

        last_bb = bb
        i += 1
        insn = finish._next
      end

      while bb = wants_label.pop
        jump_target = has_label.fetch(bb.jump_target_label)

        bb.add_edge jump_target
        jump_target.predecessors << bb
      end

      mark_set = Set.new
      head.each { |x| mark_set << x }
      # sweep unreachable blocks
      all_bbs.each { |x| x.remove unless mark_set.include?(x) }

      head = dominators head

      unless ssa
        head = dominance_frontiers head
        head = place_phi head
      end
      head
    end

    def self.dominators bbs
      all_bbs = bbs.to_a
      all_bb_set = all_bbs

      # Initialize dominance sets
      all_bbs.each_with_index do |bb, i|
        if i == 0
          bb.dominators = [bb]
        else
          bb.dominators = all_bb_set
        end
      end

      changed = true
      while changed
        changed = false

        bbs.dfs do |bb|
          temp = [bb] | bb.predecessors.drop(1).inject(bb.predecessors.first.dominators) { |set, pred|
            set & pred.dominators
          }
          if temp != bb.dominators
            bb.dominators = temp
            changed = true
          end
        end
      end
      bbs
    end

    # Compute the dominance frontiers for this cfg
    # Engineering a Compiler 2ed, Figure 9.8
    def self.dominance_frontiers head
      null = [].freeze
      head.each { _1.df = null }

      head.each do |block|
        if block.predecessors.length > 1
          block.predecessors.each do |runner|
            while runner != block.idom
              runner.df = (runner.df | [block]).freeze
              runner = runner.idom
            end
          end
        end
      end

      head
    end

    # Place phi functions based on the dominance frontiers we calculated
    def self.place_phi head
      globals = Set.new
      name_to_blocks = Hash.new { |h,k| h[k] = Set.new }

      # Engineering a Compiler Figure 9.9a
      head.each do |block|
        varkill = Set.new

        block.each_instruction do |insn|
          unless insn.put_label?
            if insn.arg1.variable? && !varkill.include?(insn.arg1)
              globals << insn.arg1
            end
            if insn.arg2.variable? && !varkill.include?(insn.arg2)
              globals << insn.arg2
            end
            if insn.out.variable?
              varkill << insn.out
              name_to_blocks[insn.out] << block
            end
          end
        end
      end

      # Engineering a Compiler Figure 9.9b
      globals.each do |x|
        worklist = name_to_blocks[x].to_a
        while b = worklist.shift
          b.df.each do |d|
            phi = d.phis.find { |phi| phi.inputs.include?(x) }
            unless phi
              d.add_phi IR::Phi.new(:phi, x, x, x)
              worklist << d
            end
          end
        end
      end
      head
    end

    include Enumerable

    attr_reader :predecessors
    attr_accessor :out1, :out2
    attr_accessor :live_out, :dominators, :df

    def self.empty name
      new name, nil, nil, nil, nil, nil
    end

    def initialize name, head, start, finish
      super
      raise "Block shouldn't start with phi" if start.phi?
      @predecessors = []
      @out1         = nil
      @out2         = nil
      @live_out     = Set.new
      @dominators   = nil
      @df           = nil
      @phis         = []
      @finish       = start
    end

    def reset
      @live_out = Set.new
    end

    def add_phi phi
      phi.unlink
      start.append phi
    end

    def phis
      phis = []
      iter = start
      loop do
        if iter.op == :phi
          phis << iter
        end
        break if iter == finish
        iter = iter._next
      end
      phis.freeze
      phis
    end

    def add_instruction insn
      raise ArgumentError unless insn
      insn.bb = self
      @finish = insn
    end

    def execution_frequency
      if labeled_entry? && start.label.name == :exit
        0.2
      else
        1
      end
    end

    def reset!
      @live_out = Set.new
    end

    def ue_vars
      # UE means "upward exposed"
      ue_vars = []
      killed = killed_vars
      iter = start
      raise unless finish
      loop do
        if ue = iter.used_variables
          ue.each do |ue_var|
            ue_vars << ue_var unless killed.include?(ue_var)
          end
        end

        break if iter == finish
        iter = iter._next
      end

      ue_vars |= child_phis(out1).reject { |var| killed.include?(var) }
      ue_vars |= child_phis(out2).reject { |var| killed.include?(var) }

      Set.new ue_vars
    end

    def killed_vars
      # UE means "upward exposed"
      killed_vars = []
      iter = start
      loop do
        killed_vars << iter.set_variable if iter.set_variable

        break if iter == finish
        iter = iter._next
      end
      killed_vars
    end

    def head?; false; end

    # Immediate dominator for this block
    def idom
      dominators[1]
    end

    def assemble asm
      each_instruction do |insn|
        next if insn.phi?

        if insn == finish
          write_phis asm, out1
          write_phis asm, out2
        end

        # FIXME: we should do this
        # If the last instruction is an unconditional jump and the following
        # block is the jump target, don't bother writing the jump.
        write_instruction asm, insn
      end
    end

    def live_in predecessor
      ue_vars | (Set.new(phis.flat_map(&:inputs)) & predecessor.ue_vars)
    end

    def add_edge edge
      raise ArgumentError if @out1 && @out2
      if @out1
        @out2 = edge
      else
        @out1 = edge
      end
    end

    def add_jump ir, label
      raise ArgumentError unless label
      add_instruction ir.insert_jump(finish, label)
    end

    def remove_predecessor block
      @predecessors.delete_if { |x| x == block }
    end

    def remove
      successors.each do |succ|
        succ.remove_predecessor self
      end

      @predecessors.each do |pred|
        pred.out1 = @out1 if pred.out1 == self
        pred.out2 = @out2 if pred.out2 == self
      end
    end

    def empty?
      start == finish && start.unconditional_jump?
    end

    ###
    # Iterate each block, breadth first
    def bfs &blk
      return enum_for(__method__) unless block_given?

      seen = {}
      worklist = [self]
      while item = worklist.pop
        unless seen[item]
          yield item
          seen[item] = true
          worklist.unshift item.out1 if item.out1
          worklist.unshift item.out2 if item.out2
        end
      end
    end

    alias :each :bfs

    ###
    # Iterate each block depth first
    def dfs &blk
      return enum_for(__method__) unless block_given?

      seen = {}
      worklist = [self]
      while item = worklist.pop
        unless seen[item]
          yield item
          seen[item] = true
          worklist.push item.out2 if item.out2
          worklist.push item.out1 if item.out1
        end
      end
    end

    def each_instruction
      return enum_for(:each_instruction) unless block_given?

      node = start
      loop do
        yield node
        break if node == finish
        node = node._next
      end
    end

    def reverse_each_instruction
      return enum_for(:reverse_each_instruction) unless block_given?

      node = finish
      loop do
        yield node
        break if node == start
        node = node.prev
      end
    end

    def falls_through?
      !(finish.unconditional_jump? || finish.return?)
    end

    def has_jump_target?
      finish.has_jump_target?
    end

    def jumps?
      finish.jump?
    end

    def returns?
      finish.return?
    end

    def calls?
      finish.call?
    end

    def jump_target_label
      finish.target_label
    end

    def labeled_entry?
      start.put_label?
    end

    def label
      start.label
    end

    def successors
      [out1, out2].compact
    end

    private

    def write_instruction asm, insn
      vr1 = insn.arg1
      vr2 = insn.arg2
      vr3 = insn.out

      # Convert this SSA instruction to machine code
      asm.handle insn, vr3, vr1, vr2
    rescue TenderJIT::Error, NoMethodError
      $stderr.puts TenderJIT::BasicBlock::Printer.new(head).to_ascii
      raise
    end

    EMPTY_SET = Set.new

    def child_phis successor
      return EMPTY_SET unless successor

      if successor.phis.any?
        live_phi = successor.phis.flat_map(&:inputs) &
          dominators.flat_map(&:killed_vars)
        live_phi
      else
        []
      end
    end

    def write_phis asm, successor
      return unless successor

      successor.phis.each do |phi|
        phi.inputs.each do |transfer|
          if live_out.include?(transfer)
            if phi.out.pr != transfer.pr
              write = IR::Instruction.new(:write, transfer, IR::NONE, phi.out)
              write_instruction asm, write
            end
          end
        end
      end
    end
  end
end

require "tenderjit/basic_block/head"
