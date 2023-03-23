require "tenderjit/util"

class TenderJIT
  class Compiler
    class Context
      class StackItem < Util::ClassGen.pos(:type, :depth, :reg)
        def depth_b; depth * Fiddle::SIZEOF_VOIDP; end

        def fixnum?
          type == :T_FIXNUM
        end
      end

      LocalItem = Util::ClassGen.pos(:type, :reg)

      include Enumerable

      attr_reader :buff, :ec, :cfp, :sp
      attr_accessor :ep

      def initialize buff, ec, cfp, sp, ep
        @ec = ec
        @cfp = cfp
        @sp = sp
        @ep = ep
        @stack = []
        @locals = {}
      end

      def initialize_copy other
        @stack = @stack.dup
        @locals = @locals.dup
      end

      def each &blk
        @stack.each(&blk)
      end

      def get_local name
        @locals.fetch(name)
      end

      def have_local? name
        @locals.key? name
      end

      def set_local name, type, register
        @locals[name] = LocalItem.new(type, register)
      end

      def stack_depth
        @stack.length
      end

      def push type, register
        item = StackItem.new(type, @stack.length, register)
        @stack.push item
        item
      end

      def top
        @stack.last
      end

      def stack_depth_b
        stack_depth * Fiddle::SIZEOF_VOIDP
      end

      # Returns the info stored for stack location +idx+.  0 is the TOP of the
      # stack, or the last thing pushed.
      def peek idx
        idx = @stack.length - idx - 1
        raise IndexError if idx < 0
        @stack.fetch(idx)
      end

      def pop
        @stack.pop
      end
    end
  end
end
