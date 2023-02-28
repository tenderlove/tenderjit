require "tenderjit/util"

class TenderJIT
  class CFG
    attr_reader :type

    def initialize basic_blocks, type
      @basic_blocks = clean(basic_blocks)
      @basic_blocks.live_ranges!
      @type = type
    end

    def clean blocks
      blocks.each do |blk|
        blk.remove if blk.empty?
      end

      blocks
    end

    def each &blk
      @basic_blocks.each &blk
    end

    def reverse_each &blk
      @basic_blocks.reverse_each &blk
    end

    def each_instruction &blk
      @basic_blocks.each_instruction &blk
    end

    def assign_registers ir
      ra.allocate @basic_blocks, ir
    end

    def ra
      if Util::PLATFORM == :arm64
        require "tenderjit/arm64/register_allocator"
        ARM64::RegisterAllocator.new
      else
        require "tenderjit/x86_64/register_allocator"
        X86_64::RegisterAllocator.new
      end
    end

    def to_dot
      $stderr.puts "digraph {"
      $stderr.puts "rankdir=TD; ordering=out;"
      $stderr.puts "node[shape=box fontname=\"Comic Code\"];"
      $stderr.puts "edge[fontname=\"Comic Code\"];"
      @basic_blocks.each do |block|
        $stderr.print block.name
        $stderr.print "[label=\"BB#{block.name}\\l"
        $stderr.print "UE:       #{type.vars block.ue_vars}\\l"
        $stderr.print "Killed:   #{type.vars block.killed_vars}\\l"
        $stderr.print "Live Out: #{type.vars block.live_out}\\l"
        if block.phis.any?
          block.phis.each do |phi|
            $stderr.print "Phi: #{type.vars [phi.out]} = "
            $stderr.print "#{type.vars phi.vars}\\l"
          end
        end
        $stderr.print "Dom:      #{block.dominators.map(&:name).join(",")}\\l"
        $stderr.print type.dump_insns block.each_instruction.to_a, ansi: false
        $stderr.puts "\"];"
        if bb = block.out1
          $stderr.puts "#{block.name} -> #{bb.name} [label=\"out1\"];"
        end
        if bb = block.out2
          $stderr.puts "#{block.name} -> #{bb.name} [label=\"out2\"];"
        end

        #block.predecessors.each do |pred|
        #  next if pred.head?
        #  $stderr.puts "#{block.name} -> #{pred.name} [color=grey style=dotted arrowhead=empty];"
        #end
      end
      $stderr.puts "}"
    end
  end

  class BasicBlockHead
    include Enumerable

    attr_accessor :out1
    attr_reader :dominators

    def initialize ssa
      @out1 = nil
      @ssa = ssa
      @dominators = Set.new
    end

    def ssa?; @ssa; end

    def name; :HEAD; end
    def predecessors; []; end

    def head?; true; end

    def falls_through?; true; end

    def jumps?; true; end

    def add_edge node
      raise ArgumentError if @out1
      @out1 = node
    end

    # Head block should only ever point at one thing
    def out2; end

    def each &blk
      @out1.each &blk
    end

    def reverse_each &blk
      @out1.reverse_each &blk
    end

    def each_instruction &blk
      return enum_for(:each_instruction) unless block_given?

      @out1.each do |bb|
        bb.each_instruction(&blk)
      end
    end

    ##
    # Calculate LiveOut and the live ranges for variables
    def live_ranges!
      if ssa?
        reverse_each do |bi|
          live = bi.live_out = bi.successors.inject(Set.new) do |set, succ|
            set | (succ.live_in(bi) | (succ.live_out - succ.killed_vars))
          end

          live.each do |opnd|
            opnd.add_range(bi.from, bi.to)
          end

          bi.reverse_each_instruction do |insn|
            insn.out.set_from(insn.number)
            insn.arg1.add_range(bi.from, insn.number)
            insn.arg2.add_range(bi.from, insn.number)
          end
        end
      else
        live_vars!
      end
    end

    private

    ##
    # Use a different algorithm for non-ssa instructions (YARV)
    def live_vars!
      changed = true
      while changed
        changed = false

        each do |bi|
          old = bi.live_out
          new = bi.successors.inject(Set.new) do |set, succ|
            set | (succ.live_in(bi) | (succ.live_out - succ.killed_vars))
          end
          if old != new
            bi.live_out = new
            changed = true
          end
        end
      end
    end
  end

  class BasicBlock < Util::ClassGen.pos(:name, :start, :finish, :phis, :ue_vars, :killed_vars)
    def self.build insn_head, ir, ssa
      head = last_bb = BasicBlockHead.new ssa
      insn = insn_head._next
      i = 0
      wants_label = []
      has_label = {}
      all_bbs = []

      while insn
        start = finish = insn

        # UE means "upward exposed"
        ue_vars = Set.new
        killed_vars = Set.new
        phis = []

        while finish._next
          if ue = finish.used_variables
            ue.each do |ue_var|
              ue_vars << ue_var unless killed_vars.include?(ue_var)
            end
          end

          killed_vars << finish.set_variable if finish.set_variable

          break if finish.jump?
          break if finish._next.put_label?
          _next = finish._next
          if finish.phi?
            phis << finish
            #finish.unlink
          end
          finish = _next
        end

        bb = BasicBlock.new(i, start, finish, phis, ue_vars, killed_vars)
        all_bbs << bb

        has_label[bb.label] = bb if bb.labeled_entry?

        wants_label << bb if bb.has_jump_target?

        if last_bb.falls_through?
          last_bb.add_edge bb
          bb.predecessors << last_bb
        end

        unless last_bb.jumps?
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

      dominators number head
    end

    ##
    # Number the instructions so we can determine the live ranges
    def self.number bbs
      bbs.each_instruction.with_index do |insn, i|
        insn.number = i
      end
      bbs
    end

    def self.dominators bbs
      all_bbs = bbs.to_a
      all_bb_set = Set.new(all_bbs)

      # Initialize dominance sets
      all_bbs.each_with_index do |bb, i|
        if i == 0
          bb.dominators = Set.new(bb)
        else
          bb.dominators = all_bb_set
        end
      end

      changed = true
      while changed
        changed = false

        bbs.each do |bb|
          temp = Set.new([bb]) | bb.predecessors.drop(1).inject(bb.predecessors.first.dominators) { |set, pred|
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

    include Enumerable

    attr_reader :predecessors
    attr_accessor :out1, :out2, :live_out, :dominators

    def initialize name, start, finish, phis, ue_vars, killed_vars
      super
      @predecessors = []
      @out1         = nil
      @out2         = nil
      @live_out     = Set.new
      @dominators   = nil
    end

    def head?; false; end

    def live_in predecessor
      used_phis = Set.new(phis.flat_map(&:vars).uniq)
      ue_vars | (predecessor.killed_vars & used_phis)
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
      @finish = ir.insert_jump finish, label
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

    def each &blk
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

    def from; start.number; end

    def to; finish.number; end

    def falls_through?
      !finish.unconditional_jump?
    end

    def has_jump_target?
      finish.has_jump_target?
    end

    def jumps?
      finish.jump?
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
  end
end
