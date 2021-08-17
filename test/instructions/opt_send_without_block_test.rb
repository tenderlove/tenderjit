# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptSendWithoutBlockTest < JITTest
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

    alias :old_p :p
    alias :old_p2 :p
    alias :old_p3 :p

    def call_p
      !"lol"
      :foo
    end

    alias :mm :call_p

    def test_call_p
      jit = TenderJIT.new
      jit.compile method(:call_p)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_p
      jit.disable!
      assert_equal :foo, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end

    def call_bang
      !"lol"
      :foo
    end

    def test_call_bang
      jit = TenderJIT.new
      jit.compile method(:call_bang)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_bang
      jit.disable!
      assert_equal :foo, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end

    def one
      three
      :lol
    end

    def three
      !"lol"
    end

    def test_deep_exit
      jit = TenderJIT.new
      jit.compile method(:one)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = one
      jit.disable!
      assert_equal :lol, v

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 1, jit.exits
    end

    def cfunc x
      Fiddle.dlwrap x
    end

    def test_cfunc
      obj = Object.new
      expected = Fiddle.dlwrap obj

      success = false
      jit = TenderJIT.new
      jit.compile(method(:cfunc))
      5.times do
        recompiles = jit.recompiles
        exits = jit.exits
        jit.enable!
        cfunc(obj)
        jit.disable!
        if recompiles == jit.recompiles && exits == jit.exits
          success = true
          break
        end
      end

      assert success, "method couldn't be heated"

      jit.enable!
      v = cfunc(obj)
      jit.disable!
      assert_equal expected, v
    end

    define_method :bmethod do |a, b|
      a + b
    end

    def call_bmethod
      bmethod(1, 2)
    end

    def test_cfunc
      assert_jit method(:call_bmethod), compiled: 2, executed: 2, exits: 0
    end
  end
end
