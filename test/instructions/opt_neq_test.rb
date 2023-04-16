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

    def opt_neq_symbol_lhs x
      :foo != x
    end

    def test_opt_neq_symbol_lhs
      expected = opt_neq_symbol_lhs(:bar)

      compile method(:opt_neq_symbol_lhs), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = opt_neq_symbol_lhs(:bar)
      jit.disable!
      assert_equal expected, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def opt_neq_unknown x, y
      x != y
    end

    def test_opt_neq_unknown_lhs
      expected = opt_neq_unknown(:foo, :bar)

      compile method(:opt_neq_unknown), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = opt_neq_unknown(:foo, :bar)
      jit.disable!
      assert_equal expected, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
