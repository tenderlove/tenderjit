require "tenderjit/register_allocator"
require "fisk"

class TenderJIT
  module X86_64
    PARAM_REGS = Fisk::Registers::CALLER_SAVED.dup.freeze

    FREE_REGS = [
      Fisk::Registers::R12,
      Fisk::Registers::R13,
    ].freeze

    class RegisterAllocator < TenderJIT::RegisterAllocator
      def initialize
        super(Fisk::Registers::RSP, PARAM_REGS, FREE_REGS)
      end
    end
  end
end
