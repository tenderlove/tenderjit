require "fisk"
require "tenderjit/jit_context"

class TenderJIT
  class DeferredCompilations
    class DeferralRequest
      attr_reader :entry

      def initialize temp_stack, jit_buf, block
        @jit_buffer = jit_buf
        @temp_stack    = temp_stack
        @entry = @jit_buffer.memory.to_i + @jit_buffer.pos
        @block = block
      end

      def call ret_loc
        fisk = Fisk.new
        @temp_stack.flush fisk

        ctx = JITContext.new(fisk, @jit_buffer, @temp_stack)

        @block.call ctx, ret_loc

        ctx.write!
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
