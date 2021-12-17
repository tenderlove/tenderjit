# frozen_string_literal: true

require "helper"

class TenderJIT
  class PutspecialobjectTest < JITTest
    def putspecialobject
      -> { 2 }.call
    end

    def test_putspecialobject
      jit.compile method(:putspecialobject)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = putspecialobject
      jit.disable!
      assert_equal 2, v

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
    end
  end
end
