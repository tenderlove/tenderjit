# frozen_string_literal: true

require "helper"

class TenderJIT
  class JITTwoMethods < Test
    def simple
      "foo"
    end

    def putself
      self
    end

    def test_compile_two_methods
      jit = TenderJIT.new
      jit.compile method(:simple)
      jit.compile method(:putself)
      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      a = simple
      b = putself
      jit.disable!

      assert_equal "foo", a
      assert_equal self, b

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
    end
  end

  class SimpleMethodJIT < Test
    def simple
      "foo"
    end

    def test_simple_method
      jit = TenderJIT.new
      jit.compile method(:simple)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = simple
      jit.disable!
      assert_equal "foo", v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
    end
  end

  class PutSelf < Test
    def putself
      self
    end

    def test_putself
      jit = TenderJIT.new
      jit.compile method(:putself)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = putself
      jit.disable!
      assert_equal self, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end

  class GetLocalWC0 < Test
    def getlocal_wc_0 x
      x
    end

    def test_getlocal_wc_0
      jit = TenderJIT.new
      jit.compile method(:getlocal_wc_0)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = getlocal_wc_0 "foo"
      jit.disable!
      assert_equal "foo", v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def getlocal_wc_0_2 x, y
      y
    end

    def test_two_locals
      jit = TenderJIT.new
      jit.compile method(:getlocal_wc_0_2)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = getlocal_wc_0_2 "foo", "bar"
      jit.disable!
      assert_equal "bar", v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end

  class HardMethodJIT < Test
    def too_hard
      "foo".to_s
    end

    def test_too_hard
      jit = TenderJIT.new
      jit.compile method(:too_hard)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = too_hard
      jit.disable!
      assert_equal "foo", v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits

      assert_equal 1, jit.exit_stats["opt_send_without_block"]
    end
  end
end
