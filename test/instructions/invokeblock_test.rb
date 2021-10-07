# frozen_string_literal: true

require "helper"

class TenderJIT
  class InvokeblockTest < JITTest
    def barr
      yield
    end

    def foor
      barr { 5 }
    end

    def test_can_invoke_block
      assert_has_insn method(:barr), insn: :invokeblock

      jit.compile(method(:foor))
      jit.enable!
      v = foor
      jit.disable!

      assert_equal 3, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 5, v
    end

    def test_compile_with_block_then_call_without
      assert_has_insn method(:barr), insn: :invokeblock

      jit.compile(method(:foor))
      jit.enable!
      foor
      assert_raises(LocalJumpError) do
        barr
      end
      jit.disable!

      assert_equal 3, jit.compiled_methods
      # We're just going to exit for the exception
      assert_equal 1, jit.exits
    end

    def test_compile_without_block_then_with
      assert_has_insn method(:barr), insn: :invokeblock

      jit.compile(method(:foor))
      jit.compile(method(:barr))
      jit.enable!
      assert_raises(LocalJumpError) do
        barr
      end
      v = foor
      jit.disable!

      assert_equal 3, jit.compiled_methods
      # We're just going to exit for the exception
      assert_equal 1, jit.exits
      assert_equal 5, v
    end
  end
end
