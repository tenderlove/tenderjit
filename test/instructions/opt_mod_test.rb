# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptModTest < JITTest
    def modulo_fixnums
      81 % 2
    end

    def modulo_non_fixnums
      81.0 % 2
    end

    def test_modulo_fixnums
      meth = method(:modulo_fixnums)

      assert_has_insn meth, insn: :opt_mod

      compile(meth, recv: self)
      jit.enable!
      result = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 1, result
    end

    def test_modulo_non_fixnums
      meth = method(:modulo_non_fixnums)

      assert_has_insn meth, insn: :opt_mod

      compile(meth, recv: self)
      jit.enable!
      result = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.exits
      assert_equal 1.0, result
    end
  end
end
