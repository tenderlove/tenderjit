# frozen_string_literal: true

require "helper"

class TenderJIT
  class SendTest < JITTest
    def bar
      5
    end

    def foo
      bar { }
    end

    def test_send_with_block
      jit.compile(method(:foo))
      jit.enable!
      v = foo
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 5, v
    end

    def barr
      yield
    end

    def foor
      barr { 5 }
    end

    def test_send_with_block_yields
      jit.compile(method(:foor))
      jit.enable!
      v = foor
      jit.disable!

      assert_equal 3, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 5, v
    end

    def gimme
      yield(15)
      :hello
    end

    def return_gimme
      x = 0
      gimme { |m| x += m }
      x
    end

    def test_block_params_work
      jit.compile(method(:gimme))
      jit.compile(method(:return_gimme))

      expected = return_gimme
      jit.enable!
      v = return_gimme
      jit.disable!

      assert_equal 3, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, v
    end

    def only_gimme
      gimme { |x| }
    end

    # Test that the block will be called and we return the original value
    # of the `gimme` method
    def test_only_gimme
      jit.compile(method(:gimme))
      jit.compile(method(:only_gimme))

      expected = return_gimme
      jit.enable!
      v = return_gimme
      jit.disable!

      assert_equal 3, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, v
    end

    def run_each x
      i = 0
      x.each { |m| i += m }
      i
    end

    def test_cfunc_with_block
      jit.compile(method(:run_each))

      expected = run_each([1, 2, 3])
      jit.enable!
      actual = run_each([1, 2, 3])
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end
    def block_takes_iseq_block &blk
      m = nil
      [1, 1].each do
        m = blk.call(2) { "neat" }
      end
      m
    end

    def test_block_takes_block
      expected = block_takes_iseq_block { |_, &blk| blk.call }

      jit.compile(method(:block_takes_iseq_block))

      jit.enable!
      actual = block_takes_iseq_block { |_, &blk| blk.call }
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end

  end
end
