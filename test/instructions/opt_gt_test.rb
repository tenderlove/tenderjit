# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptGtTest < JITTest
    def gt_false
      1 > 2
    end

    def gt_true
      2 > 1
    end

    def gt_params x, y
      x > y
    end

    def test_gt_true
      jit = TenderJIT.new
      jit.compile method(:gt_true)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = gt_true
      jit.disable!
      assert_equal true, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_gt_false
      jit = TenderJIT.new
      jit.compile method(:gt_false)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = gt_false
      jit.disable!
      assert_equal false, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_gt_params
      jit = TenderJIT.new
      jit.compile method(:gt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = gt_params(2, 1)
      jit.disable!
      assert_equal true, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_gt_exits
      jit = TenderJIT.new
      jit.compile method(:gt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = gt_params("bar", "foo")
      jit.disable!
      assert_equal false, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end

    def test_gt_left_exits
      jit = TenderJIT.new
      jit.compile method(:gt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      begin
        gt_params("foo", 1)
        flunk
      rescue ArgumentError
      end
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end

    def test_gt_right_exits
      jit = TenderJIT.new
      jit.compile method(:gt_params)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      begin
        gt_params(1, "foo")
        flunk
      rescue ArgumentError
      end
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 1, jit.exits
    end
  end
end
