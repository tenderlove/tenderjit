require "tenderjit/util"

class TenderJIT
  module LinkedList
    module Element
      attr_accessor :_next, :prev

      include Enumerable

      def initialize ...
        super(...)
        @_next = nil
        @prev = nil
      end

      def head?
        false
      end

      def append node
        @_next.prev = node if @_next
        node._next = @_next
        node.prev = self
        @_next = node
        node
      end

      def unlink
        prev._next = @_next if prev
        @_next.prev = prev if @_next
      end

      def each
        node = @_next
        while node
          yield node
          node = node._next
        end
      end
    end

    class Head
      include Element

      def head?
        true
      end
    end
  end
end
