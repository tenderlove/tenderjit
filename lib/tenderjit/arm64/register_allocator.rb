require "tenderjit/register_allocator"
require "aarch64"

class TenderJIT
  module ARM64
    PARAM_REGS = 8.times.map { AArch64::Registers.const_get(:"X#{_1}") }.freeze

    FREE_REGS = [
      AArch64::Registers::X9,
      AArch64::Registers::X10,
    ].freeze

    class RegisterAllocator < TenderJIT::RegisterAllocator
      def initialize
        super(PARAM_REGS, FREE_REGS)
      end
    end
  end
end
