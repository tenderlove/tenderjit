require "tenderjit/util"

class TenderJIT
  class IR
    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out, :_next, :prev, :number)
      attr_writer :prev
      attr_writer :number

      def append node
        @_next = node
        node.prev = self
        node
      end

      def put_label?
        op == :put_label
      end

      def jump?
        !put_label? && (out.label? || op == :return)
      end

      def unconditional_jump?
        op == :return || op == :jmp
      end

      def has_jump_target?
        out.label?
      end

      def label
        raise unless put_label?
        out
      end

      def target_label
        return out if out.label?
        raise "not a jump instruction"
      end
    end

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
  end
end
