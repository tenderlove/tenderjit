# frozen_string_literal: true

require "helper"

class TenderJIT
  class BranchUnless < JITTest
    def compare a, b
      if a < b
        :cool
      else
        :other_cool
      end
    end

    def test_branchunless
      jit = TenderJIT.new
      jit.compile method(:compare)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = compare(1, 2)
      jit.disable!
      assert_equal :cool, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_branchunless_other_side
      jit = TenderJIT.new
      jit.compile method(:compare)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = compare(2, 1)
      jit.disable!
      assert_equal :other_cool, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
