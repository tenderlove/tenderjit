require "fisk"
require "tenderjit/runtime"

class TenderJIT
  class JITContext
    attr_reader :fisk

    def initialize fisk, jit_buffer, temp_stack
      @jit_buffer = jit_buffer
      @fisk       = fisk
      @temp_stack = temp_stack
    end

    def flush
      write!
      @fisk = Fisk.new
    end

    def with_runtime
      yield Runtime.new(fisk, @jit_buffer, @temp_stack)
    end

    def write!
      fisk.release_all_registers
      fisk.assign_registers(TenderJIT::ISEQCompiler::SCRATCH_REGISTERS, local: true)
      fisk.write_to @jit_buffer
      @fisk.freeze
    end
  end
end
