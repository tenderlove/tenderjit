# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptMultTest < JITTest
    def multiply_literals
      2 * 2
    end

    def multiply_non_numbers
      "^" * 10
    end

    def test_multiply_literals
      jit.compile method(:multiply_literals)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = multiply_literals
      jit.disable!
      assert_equal 4, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_multiply_non_numbers
      expected = multiply_non_numbers
      jit.compile method(:multiply_non_numbers)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = multiply_non_numbers
      jit.disable!
      assert_equal expected, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
