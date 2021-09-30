# frozen_string_literal: true

require "helper"

class TenderJIT
  class NewarrayTest < JITTest
    def bar; 1; end

    def foo
      [bar, bar, bar]
    end

    def test_newarray
      jit.compile(method(:foo))
      jit.enable!
      v = foo
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [1, 1, 1], v
    end
  end
end
