# frozen_string_literal: true

require "helper"

class TenderJIT
  class BranchunlessTest < JITTest
    def compare a, b
      if a < b
        :cool
      else
        :other_cool
      end
    end

    def test_branchunless
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

    def compare_and_use a, b
      (a < b ? 5 : 6) + 5
    end

    def test_phi_function_for_stack
      jit.compile method(:compare_and_use)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = compare_and_use(1, 2)
      assert_equal 10, v

      v = compare_and_use(2, 1)
      assert_equal 11, v

      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
