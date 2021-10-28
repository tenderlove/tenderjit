# frozen_string_literal: true

require "helper"

class TenderJIT
  class SwapTest < JITTest
    def method_with_swap
      defined?([[]])
    end

    def test_swap
      m = method(:method_with_swap)

      assert_has_insn m, insn: :swap

      jit.compile(m)
      jit.enable!
      v = m.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal "expression", v
    end
  end
end
