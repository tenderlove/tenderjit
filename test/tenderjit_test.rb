# frozen_string_literal: true

require "helper"

class TenderJIT
  class CodeBlockTest < Test
    def lt_true
      1 < 2
    end

    def test_compile_adds_codeblock
      jit = TenderJIT.new
      jit.compile method(:lt_true)
      cbs = jit.code_blocks(method(:lt_true))
      assert_equal 1, cbs.length
    ensure
      jit.uncompile method(:lt_true)
    end

    def test_uncompile_removes_codeblocks
      jit = TenderJIT.new
      jit.compile method(:lt_true)
      cbs = jit.code_blocks(method(:lt_true))
      assert_equal 1, cbs.length
      jit.uncompile method(:lt_true)
      cbs = jit.code_blocks(method(:lt_true))
      assert_nil cbs
    end

    def test_uncompile_without_compile
      jit = TenderJIT.new
      jit.uncompile method(:lt_true)
      cbs = jit.code_blocks(method(:lt_true))
      assert_nil cbs
    end
  end

  class OptLT < Test
    def lt_true
      1 < 2
    end

    def lt_false
      2 < 1
    end

    def lt_params x, y
      x < y
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
    def fun a, b
      a < b
    end

    def too_hard
      fun(1, 2)
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
