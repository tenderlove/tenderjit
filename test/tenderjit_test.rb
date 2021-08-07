# frozen_string_literal: true

require "helper"

class TenderJIT
  class IterFib < JITTest
    def call_fib
      fib 50
    end

    def fib num
      a = 0
      b = 1

      while num > 0
        temp = a
        a = b
        b = temp + b
        num -= 1
      end

      a
    end

    def test_fib_iter
      v = assert_jit method(:call_fib), compiled: 2, executed: 2, exits: 0
      assert_equal 12586269025, v
    end
  end

  class MethodRecursion < JITTest
    def fib n
      if n < 3
        1
      else
        fib(n - 1) + fib(n - 2)
      end
    end

    def test_fib
      jit = TenderJIT.new
      jit.compile method(:fib)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = fib(5)
      jit.disable!
      assert_equal 5, v

      assert_equal 1, jit.compiled_methods
      assert_equal 9, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def cool a
      if a < 1
        :cool
      else
        cool(a - 1)
      end
    end

    def test_recursive
      jit = TenderJIT.new
      jit.compile method(:cool)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = cool(3)
      jit.disable!
      assert_equal :cool, v

      assert_equal 1, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
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

  class HardMethodJIT < JITTest
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
