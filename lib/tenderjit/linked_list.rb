require "tenderjit/util"

class TenderJIT
  module LinkedList
    class Head < Util::ClassGen.pos(:_next)
      include Enumerable

      attr_writer :_next

      def head?
        true
      end

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

    module Element
      attr_accessor :_next, :prev

      def initialize ...
        super(...)
        @_next = nil
        @prev = nil
      end

      def head?
        false
      end

      def append node
        @_next = node
        node.prev = self
        node
      end

      def insert node
        node._next = @_next
        node.prev = self
        @_next = node
        node
      end

      def unlink
        prev._next = @_next
        @_next.prev = prev
      end
    end
  end
end
