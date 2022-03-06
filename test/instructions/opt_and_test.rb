# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptAndTest < JITTest
    def thing
      3 & 5
    end

    def test_opt_and
      expected = thing

      jit.compile method(:thing)

      jit.enable!
      actual = thing
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def thing2 a, b
      a & b
    end

    def test_opt_and_param
      expected = thing2(3, 5)

      jit.compile method(:thing2)

      jit.enable!
      actual = thing2(3, 5)
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class And; def & x; "lol"; end; end

    def test_opt_and_not_fixnum
      annd = And.new
      expected = thing2(annd, 5)

      jit.compile method(:thing2)

      jit.enable!
      actual = thing2(annd, 5)
      jit.disable!
      assert_equal expected, actual

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
