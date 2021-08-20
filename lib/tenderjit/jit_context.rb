require "fisk"
require "tenderjit/runtime"

class TenderJIT
  class JITContext
    attr_reader :fisk

    def initialize fisk, jit_buffer
      @jit_buffer = jit_buffer
      @fisk = fisk
    end

    def flush
      write!
      @fisk = Fisk.new
    end

    def with_runtime
      yield Runtime.new(fisk, @jit_buffer)
    end

    def write!
      fisk.release_all_registers
      fisk.assign_registers(TenderJIT::ISEQCompiler::SCRATCH_REGISTERS, local: true)
      fisk.write_to @jit_buffer
    end
  end
end
