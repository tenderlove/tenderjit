require "fisk"

class TenderJIT
  class DeferredCompilations
    class DeferralRequest
      attr_reader :entry

      def initialize jit_buf, block
        @jit_buffer = jit_buf
        @entry = @jit_buffer.memory.to_i + @jit_buffer.pos
        @block = block
      end

      def call ret_loc
        fisk = Fisk.new
        @block.call fisk, ret_loc
        fisk.release_all_registers
        fisk.assign_registers([fisk.r9, fisk.r10], local: true)
        fisk.write_to @jit_buffer
      end
    end

    def initialize
      @jit_buffer = Fisk::Helpers.jitbuffer(4096 * 4)
    end

    def deferred_call(&block)
      DeferralRequest.new(@jit_buffer, block)
    end
  end
end
