require "tenderjit/util"

class TenderJIT
  class CFG
    def initialize basic_blocks
      @basic_blocks = clean(basic_blocks)
    end

    def clean blocks
      blocks.each do |blk|
        p :REMOVING => blk.name if blk.empty?
        blk.remove if blk.empty?
      end

      blocks
    end

    def tsort
      @basic_blocks.to_a
    end

    def number_instructions!
      i = 0
      @basic_blocks.each do |basic_block|
        basic_block.each_instruction do |insn|
          insn.number = i
          i += 1
        end
      end
    end

    def to_dot type
      $stderr.puts "digraph {"
      $stderr.puts "node[shape=box fontname=\"Comic Code\"];"
      tsort_each_node do |block|
        $stderr.print block.name
        $stderr.print "[label=\"BB#{block.name}\\l"
        $stderr.print type.dump_insns block.each_instruction.to_a, ansi: false
        $stderr.puts "\"];"
        if bb = block.out1
          $stderr.puts "#{block.name} -> #{bb.name} [label=\"out1\"];"
        end
        if bb = block.out2
          #if block.jumps_backward?
            $stderr.puts "#{block.name} -> #{bb.name} [label=\"out2\"];"
          #else
          #  $stderr.puts "#{block.name} -> #{bb.name} [label=\"forward jump\"];"
          #end
        end
      end
      $stderr.puts "}"
    end
  end

  class BasicBlockHead
    include Enumerable

    attr_accessor :out1
    attr_reader :out2 # Head block should only ever point at one thing

    def initialize
      @out1 = nil
      @out2 = nil
    end

    def head?; true; end

    def falls_through?; true; end

    def jumps?; true; end

    def add_edge node
      raise ArgumentError if @out1
      @out1 = node
    end

    def each &blk
      @out1.each &blk
    end
  end

  class BasicBlock < Util::ClassGen.pos(:name, :start, :finish)
    def self.build insn_head, ir
      head = last_bb = BasicBlockHead.new
      insn = insn_head._next
      i = 0
      wants_label = []
      has_label = {}

      while insn
        start = finish = insn

        while finish._next && !finish._next.put_label?
          break if finish.jump?
          finish = finish._next
        end

        bb = BasicBlock.new(i, start, finish)

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

      head
    end

    include Enumerable

    attr_reader :predecessors
    attr_accessor :out1, :out2

    def initialize name, start, finish
      super
      @predecessors = []
      @out1 = nil
      @out2 = nil
    end

    def head?; false; end

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

    def remove
      raise unless empty?

      @predecessors.each do |pred|
        pred.out1 = @out1 if pred.out1 == self
        pred.out2 = @out2 if pred.out2 == self
      end
    end

    def empty?
      start == finish && start.jump?
    end

    def each &blk
      seen = {}
      worklist = [self]
      while item = worklist.pop
        unless seen[item]
          yield item
          seen[item] = true
          worklist << item.out2 if item.out2
          worklist << item.out1 if item.out1
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
