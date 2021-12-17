# frozen_string_literal: true

require "helper"

class TenderJIT
  class SetlocalWc1Test < JITTest
    def setlocal_WC_1(a = 2)
      proc { a = 3 }
      a
    end

    def test_setlocal_WC_1
      assert_has_insn method(:setlocal_WC_1), insn: :setlocal_WC_1

      # compiled equals 2 because compiled blocks count as compiled method.
      v = assert_jit method(:setlocal_WC_1), compiled: 2, executed: 1, exits: 0
      assert_equal 2, v
    end
  end
end
