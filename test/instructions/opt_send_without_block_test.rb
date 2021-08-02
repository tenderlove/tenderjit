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
  end
end
