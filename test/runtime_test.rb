# frozen_string_literal: true

require "helper"

class TenderJIT
  class RuntimeTest < Test
    attr_reader :rt

    def setup
      super

      fisk = Fisk.new
      jit_buffer = Fisk::Helpers::JITBuffer.new(Fisk::Helpers.mmap_jit(4096), 4096)
      temp_stack = TempStack.new

      @rt = Runtime::new(fisk, jit_buffer, temp_stack)
    end

    # Smoke test.
    #
    def test_if_eq_imm_imm64
      @rt.if_eq(2 << 0, 2 << 32)
    end

    # Smoke test.
    #
    def test_if_eq_imm_immnot64
      @rt.if_eq(2 << 0, 2 << 0)
    end
  end # class RuntimeTest
end
