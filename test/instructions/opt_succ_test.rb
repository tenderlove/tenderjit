# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptSuccTest < JITTest
    # Disasm for 3.0.2:
    #
    #   0000 putobject                              64                        (   1)[Li]
    #   0002 opt_succ                               <calldata!mid:succ, argc:0, ARGS_SIMPLE>
    #   0004 leave
    #
    def succ
      64.succ
    end

    # This will perform a standard method call, since the value is not a fixnum.
    #
    def succ_non_fixnum
      'c64'.succ
    end

    def test_opt_succ
      meth = method :succ

      assert_has_insn meth, insn: :opt_succ

      jit.compile meth
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 65, v
    end

    def test_opt_succ_non_fixnum
      meth = method :succ_non_fixnum

      assert_has_insn meth, insn: :opt_succ

      jit.compile meth
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 'c65', v
    end
  end
end
