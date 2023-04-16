# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptNeqTest < JITTest
    def is_not_equal
      3 != 3
    end

    def test_opt_neq
      expected = is_not_equal

      compile method(:is_not_equal), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = is_not_equal
      jit.disable!
      assert_equal expected, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
