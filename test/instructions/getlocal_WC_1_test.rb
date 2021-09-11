# frozen_string_literal: true

require "helper"

class TenderJIT
  class GetlocalWc1Test < JITTest
    name = "hello"

    define_method(:ok) { name }

    def test_getlocal_WC_1
      assert_has_insn method(:ok), insn: :getlocal_WC_1

      v = assert_jit method(:ok), compiled: 1, executed: 1, exits: 0

      assert_equal "hello", v
    end
  end
end
