class TenderJIT
  module ARM64
    PARAM_REGS = 8.times.map { AArch64::Registers.const_get(:"X#{_1}") }.freeze
    FREE_REGS = [
      AArch64::Registers::X9,
      AArch64::Registers::X10,
    ].freeze

    # This is a _local_ register allocator, it doesn't deal with register
    # allocation across basic blocks.  Also it won't spill registers, it
    # just crashes
    class RegisterAllocator
      def initialize
        @parameter_registers = ARM64::PARAM_REGS
        @freelist            = ARM64::FREE_REGS.dup
      end

      def ensure virt
        return virt.physical_register if virt.physical_register

        if virt.param?
          virt.physical_register = @parameter_registers[virt.name]
        else
          alloc virt
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
