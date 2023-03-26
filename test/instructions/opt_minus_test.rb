# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptMinusTest < JITTest
    def sub_lits
      4 - 1
    end

    def sub_params a, b
      a - b
    end

    def sub_lit_and_param a
      a - 2
    end

    def test_sub_lits
      compile method(:sub_lits), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = sub_lits
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_sub_params
      compile method(:sub_params), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = sub_params(4, 1)
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_sub_lit_and_params
      compile method(:sub_lit_and_param), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = sub_lit_and_param(5)
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_sub_strings_bails
      compile method(:sub_params), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!

      assert_raises(NoMethodError) do
        sub_params("foo", "bar")
      end

      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end
  end

end
