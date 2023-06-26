# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptLtltTest < JITTest
    def shovel
      [] << 1
    end

    def test_opt_ltlt
      compile method(:shovel), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = shovel
      jit.disable!
      assert_equal [1], v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
