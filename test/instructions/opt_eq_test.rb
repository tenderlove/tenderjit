# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptEqTest < JITTest
    def is_equal
      3 == 3
    end

    def test_opt_eq
      expected = is_equal

      jit.compile method(:is_equal)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = is_equal
      jit.disable!
      assert_equal expected, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
