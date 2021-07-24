class TenderJIT
  class TempStack
    Item = Struct.new(:name, :type, :loc)

    def initialize
      @stack = []
      @sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")
    end

    # Returns the info stored for stack location +idx+
    def peek idx
      @stack.fetch idx
    end

    # Push a value on the temp stack. Returns the memory location where
    # to write the actual value in machine code.
    def push name, type: nil
      m = Fisk::M64.new(REG_SP, @stack.length * @sizeof_sp)
      @stack.push Item.new(name, type, m)
      m
    end

    # Pop a value from the temp stack. Returns the memory location where the
    # value should be read in machine code.
    def pop
      @stack.pop.loc
    end

    def size
      @stack.size
    end
  end
end
