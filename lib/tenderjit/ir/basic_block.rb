require "tenderjit/util"
require "tsort"

class TenderJIT
  class IR
    class CFG
      include TSort

      def initialize basic_blocks
        @basic_blocks = basic_blocks
      end

      def tsort_each_node &blk
        @basic_blocks.each &blk
      end

      def tsort_each_child node, &blk
        yield node.fall_through if node.fall_through
        yield node.jump_target if node.jump_target && node.jumps_forward?
      end

      def number_instructions!
        i = 0
        tsort.reverse_each do |basic_block|
          basic_block.each do |insn|
            insn.number = i
            i += 1
          end
        end
      end
    end

    class BasicBlock < Util::ClassGen.pos(:name, :start, :finish, :jumps_back)
      include Enumerable

      attr_accessor :fall_through, :jump_target
      attr_reader :predecessors

      def initialize name, start, finish, jumps_back
        super
        @fall_through = nil
        @jump_target = nil
        @predecessors = []
      end

      def jumps_backward?
        raise unless jump_target
        jumps_back
      end

      def jumps_forward?
        !jumps_backward?
      end

      def each
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
        [fall_through, jump_target].compact
      end
    end
  end
end
