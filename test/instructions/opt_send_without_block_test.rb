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

    def test_call_bmethod
      v = assert_jit method(:call_bmethod), compiled: 2, executed: 2, exits: 0
      assert_equal 3, v
    end

    def test_call_bmethod_twice
      jit.compile method(:call_bmethod)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      call_bmethod
      v = call_bmethod
      jit.disable!
      assert_equal 3, v

      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class A; end

    def wow m
      m.foo
    end

    def wow2 m
      m.foo(m)
    end

    def test_subclass_bmethod
      x = Class.new(A) {
        define_method(:foo) { self }
      }

      x1 = x.new
      x2 = x.new

      jit.compile method(:wow)

      jit.enable!
      v1 = wow(x1)
      v2 = wow(x2)
      jit.disable!

      assert_same x1, v1
      assert_same x2, v2

      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class B
      def initialize
        @omg = Class.new {
          attr_reader :x

          def initialize x
            @x = x
          end
        }
      end

      def foo m
        @omg.new self
      end
    end

    def test_iseq_self
      x1 = B.new
      x2 = B.new
      x3 = B.new

      jit.compile method(:wow2)

      jit.enable!
      v1 = wow2(x1)
      v2 = wow2(x2)
      v3 = wow2(x3)
      jit.disable!

      assert_same x1, v1.x
      assert_same x2, v2.x
      assert_same x3, v3.x

      assert_equal 2, jit.compiled_methods
      assert_equal 6, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
