require "fisk"

class TenderJIT
  class DeferredCompilations
    class DeferralRequest
      attr_reader :entry

      def initialize ts, jit_buf, block
        @jit_buffer = jit_buf
        @ts    = ts
        @entry = @jit_buffer.memory.to_i + @jit_buffer.pos
        @block = block
      end

      def call ret_loc
        fisk = Fisk.new
        @ts.flush fisk

        @block.call fisk, ret_loc
        fisk.release_all_registers
        fisk.assign_registers(TenderJIT::ISEQCompiler::SCRATCH_REGISTERS, local: true)
        fisk.write_to @jit_buffer
      end
    end

    def initialize jit_buffer
      @jit_buffer = jit_buffer
    end

    def deferred_call(temp_stack, &block)
      DeferralRequest.new(temp_stack.dup, @jit_buffer, block)
    end
  end
end
