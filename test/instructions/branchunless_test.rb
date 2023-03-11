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

    def check_truth x
      if x
        :true
      else
        :false
      end
    end

    def test_nil_and_false_are_false
      jit.compile method(:check_truth)
      assert_equal 1, jit.compiled_methods

      jit.enable!
      assert_equal :false, check_truth(false)
      assert_equal :false, check_truth(nil)
      assert_equal :true, check_truth(true)
      assert_equal :true, check_truth(Object.new)
      assert_equal :true, check_truth(Object.new)
      assert_equal :true, check_truth(0)

      assert_equal 6, jit.executed_methods
    end
  end
end
