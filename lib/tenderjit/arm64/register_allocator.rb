require "aarch64"
require "set"

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
      class Error < StandardError; end
      class Spill < Error; end
      class DoubleFree < Error; end

      attr_reader :scratch_regs

      def initialize
        @parameter_registers = ARM64::PARAM_REGS
        @scratch_regs        = Set.new(ARM64::FREE_REGS)
        @freelist            = @scratch_regs.to_a
      end

      def ensure virt
        if virt.physical_register
          virt.physical_register
        else
          if virt.param?
            virt.physical_register = @parameter_registers[virt.name]
          else
            alloc virt
          end
        end
      end

      def alloc r
        phys = @freelist.pop
        if phys
          r.physical_register = phys
        else
          raise Spill, "Spill!"
        end
      end

      def free phys
        raise DoubleFree, "Don't free registers twice!" if @freelist.include?(phys)
        if @scratch_regs.include? phys
          @freelist.push phys
        end
      end
    end
  end
end
