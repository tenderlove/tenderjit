# frozen_string_literal: true

require "helper"

class TenderJIT
  class JITTest < Test
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
      assert_equal "foo", simple
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
    end
  end
end
