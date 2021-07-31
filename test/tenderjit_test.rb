# frozen_string_literal: true

require "helper"

class TenderJIT
  class DupArray < JITTest
    def duparray
      a = [1, 2]
      a
    end

    def test_duparray
      jit = TenderJIT.new
      jit.compile method(:duparray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = duparray
      jit.disable!
      assert_equal [1, 2], v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    ensure
      jit.uncompile method(:duparray)
    end
  end

  class CodeBlockTest < JITTest
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

  class OptPlus < JITTest
    def add_lits
      1 + 2
    end

    def add_params a, b
      a + b
    end

    def add_lit_and_param a
      a + 2
    end

    def test_add_lits
      jit = TenderJIT.new
      jit.compile method(:add_lits)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = add_lits
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_add_params
      jit = TenderJIT.new
      jit.compile method(:add_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = add_params(1, 2)
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_add_lit_and_params
      jit = TenderJIT.new
      jit.compile method(:add_lit_and_param)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = add_lit_and_param(1)
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_add_strings_bails
      jit = TenderJIT.new
      jit.compile method(:add_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = add_params("foo", "bar")
      jit.disable!
      assert_equal "foobar", v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end
  end

  class OptLT < JITTest
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

  class JITTwoMethods < JITTest
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

  class SimpleMethodJIT < JITTest
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

  class PutSelf < JITTest
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

  class GetLocalWC0 < JITTest
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

  class HardMethodJIT < JITTest
    def fun a, b
      a < b
    end

    def call_function_simple
      fun(1, 2)
    end

    def test_method_call
      jit = TenderJIT.new
      jit.compile method(:call_function_simple)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_function_simple
      jit.disable!
      assert_equal true, v

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def fun2 a, b
      a < b
    end

    def call_with_block
      a = [1, 2]
      fun2(*a)
    end

    def test_funcall_with_splat
      jit = TenderJIT.new
      jit.compile method(:call_with_block)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_with_block
      jit.disable!
      assert_equal true, v

      # Both `call_with_block` and `fun2` get compiled. `call_with_block`
      # bails on `opt_send_without_block` but Ruby re-enters the JIT for
      # `fun2`.  So we get 2 compilations, 2 executions, and 1 exit
      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 1, jit.exits
    end
  end
end
