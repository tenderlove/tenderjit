# frozen_string_literal: true

class TenderJIT
  class TempStack
    class Item < Struct.new(:name, :type, :loc)
      def symbol?
        type == Ruby::T_SYMBOL
      end

      def fixnum?
        type == Ruby::T_FIXNUM
      end
    end

    def initialize
      @stack = []
      @sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")
    end

    def freeze
      @stack.freeze
      super
    end

    # Flush the SP to the CFP within the +fisk+ context
    def flush fisk
      temp = fisk.register
      fisk.lea(temp, fisk.m(REG_BP, size * @sizeof_sp))
          .mov(fisk.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), temp)
      fisk.release_register temp
    end

    # Returns the info stored for stack location +idx+.  0 is the TOP of the
    # stack, or the last thing pushed.
    def peek idx
      stack_idx = @stack.length - idx - 1
      raise IndexError if [idx, stack_idx].any?(&:negative?)
      @stack.fetch(stack_idx)
    end

    # Returns the stack location +idx+.  0 is the TOP of the stack, or the last
    # thing that was pushed.
    def [] idx
      peek(idx).loc
    end

    def first num = nil
      if num
        @stack.last(num)
      else
        @stack.last
      end
    end

    # Push a value on the temp stack. Returns the memory location where
    # to write the actual value in machine code.
    def push name, type: nil
      m = Fisk::M64.new(REG_BP, size * @sizeof_sp)
      @stack.push Item.new(name, type, m)
      m
    end

    # Pop a value from the temp stack. Returns the memory location where the
    # value should be read in machine code.
    def pop
      @stack.pop.loc
    end

    def last
      @stack.last
    end

    # Pop an item from the temp stack. Returns an instannce of TempStack::Item
    def pop_item
      @stack.pop
    end

    def initialize_copy other
      @stack = other.stack.dup
      super
    end

    # Get an operand for the stack pointer plus some bytes
    def + bytes
      Fisk::M64.new(REG_BP, (@stack.length * @sizeof_sp) + bytes)
    end

    # Get an operand for the stack pointer plus some bytes
    def - bytes
      Fisk::M64.new(REG_BP, (@stack.length * @sizeof_sp) - bytes)
    end

    def size
      @stack.size
    end

    def empty?
      @stack.empty?
    end

    protected

    attr_reader :stack
  end
end
