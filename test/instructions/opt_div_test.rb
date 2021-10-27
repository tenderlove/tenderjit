# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptDivTest < JITTest
    def divide_fixnums
      64 / 2
    end

    def divide_non_fixnums
      2.0 / 2
    end

    def test_divide_fixnums
      meth = method(:divide_fixnums)

      assert_has_insn meth, insn: :opt_div

      jit.compile(meth)
      jit.enable!
      result = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 32, result
    end

    def test_divide_non_fixnums
      meth = method(:divide_non_fixnums)

      assert_has_insn meth, insn: :opt_div

      jit.compile(meth)
      jit.enable!
      result = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 1.0, result
    end
  end
end
