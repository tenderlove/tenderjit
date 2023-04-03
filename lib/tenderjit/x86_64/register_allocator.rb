require "tenderjit/register_allocator"
require "fisk"

class TenderJIT
  module X86_64
    PARAM_REGS = [
      Fisk::Registers::R9,
      Fisk::Registers::R8,
      Fisk::Registers::RCX,
      Fisk::Registers::RDX,
      Fisk::Registers::RSI,
      Fisk::Registers::RDI,
    ].reverse

    FREE_REGS = [
      Fisk::Registers::R11,
      Fisk::Registers::R10,
      Fisk::Registers::R9,
      Fisk::Registers::R8,
      Fisk::Registers::RCX,
      Fisk::Registers::RDX,
      Fisk::Registers::RSI,
      Fisk::Registers::RDI,
    ].freeze

    class RegisterAllocator < TenderJIT::RegisterAllocator
      include Fisk::Registers

      def initialize
        super(RSP, PARAM_REGS, FREE_REGS, RAX)
      end
    end
  end
end
