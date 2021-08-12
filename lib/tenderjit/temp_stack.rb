# frozen_string_literal: true

class TenderJIT
  class TempStack
    Item = Struct.new(:name, :type, :loc)

    def initialize
      @stack = []
      @sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")
    end

    # Flush the SP to the CFP within the +fisk+ context
    def flush fisk
      temp = fisk.register
      fisk.lea(temp, fisk.m(REG_BP, size * @sizeof_sp))
          .mov(fisk.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), temp)
      fisk.release_register temp
    end

    # Returns the info stored for stack location +idx+
    def peek idx
      @stack.fetch idx
    end

    def last
      @stack.last
    end

    # Push a value on the temp stack. Returns the memory location where
    # to write the actual value in machine code.
    def push name, type: nil
      m = Fisk::M64.new(REG_BP, @stack.length * @sizeof_sp)
      @stack.push Item.new(name, type, m)
      m
    end

    # Pop a value from the temp stack. Returns the memory location where the
    # value should be read in machine code.
    def pop
      @stack.pop.loc
    end

    def initialize_copy other
      @stack = other.stack.dup
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

    protected

    attr_reader :stack
  end
end
