# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptLeTest < JITTest
    def lt_true
      1 <= 2
    end

    def lt_false
      2 <= 1
    end

    def lt_params x, y
      x <= y
    end

    def test_lt_true
      jit = TenderJIT.new
      jit.compile method(:lt_true)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = lt_true
      jit.disable!
      assert_equal true, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_lt_false
      jit = TenderJIT.new
      jit.compile method(:lt_false)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = lt_false
      jit.disable!
      assert_equal false, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_lt_params
      jit = TenderJIT.new
      jit.compile method(:lt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = lt_params(1, 2)
      jit.disable!
      assert_equal true, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    ensure
      jit.uncompile method(:lt_params)
    end

    def test_lt_exits
      jit = TenderJIT.new
      jit.compile method(:lt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = lt_params("foo", "bar")
      jit.disable!
      assert_equal false, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    ensure
      jit.uncompile method(:lt_params)
    end

    def test_lt_left_exits
      jit = TenderJIT.new
      jit.compile method(:lt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      begin
        lt_params("foo", 1)
        flunk
      rescue ArgumentError
      end
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    ensure
      jit.uncompile method(:lt_params)
    end

    def test_lt_right_exits
      jit = TenderJIT.new
      jit.compile method(:lt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      begin
        lt_params(1, "foo")
        flunk
      rescue ArgumentError
      end
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    ensure
      jit.uncompile method(:lt_params)
    end
  end
end
