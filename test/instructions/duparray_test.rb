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
end
