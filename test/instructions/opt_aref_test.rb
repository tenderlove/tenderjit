# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptArefTest < JITTest
    def aref obj, key
      obj[key]
    end

    def test_has_opt_aref
      assert_has_insn method(:aref), insn: :opt_aref
    end

    def test_opt_aref
      jit = TenderJIT.new
      jit.compile method(:aref)

      jit.enable!
      v = aref([1, 2, 3], 2)
      jit.disable!

      assert_equal 3, v
      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
