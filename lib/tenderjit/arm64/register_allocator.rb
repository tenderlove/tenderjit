class TenderJIT
  module ARM64
    # This is a _local_ register allocator, it doesn't deal with register
    # allocation across basic blocks.  Also it won't spill registers, it
    # just crashes
    class RegisterAllocator
      def initialize
        @parameter_registers = ARM64::PARAM_REGS
        @freelist            = ARM64::FREE_REGS.dup
      end

      def ensure r
        return r.physical_register if r.physical_register

        if r.param?
          r.physical_register = @parameter_registers[r.name]
        else
          alloc r
        end
      end

      def alloc r
        phys = @freelist.pop
        if phys
          r.physical_register = phys
          phys
        else
          raise "Spill!"
        end
      end

      def free phys
        @freelist.push phys
      end
    end
  end
end
