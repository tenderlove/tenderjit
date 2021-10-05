# frozen_string_literal: true

require "helper"

class TenderJIT
  class SetlocalWc0Test < JITTest
    # Disassembly of the inner code (as of v3.1.0):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(3,3)> (catch: FALSE)
    #     0000 putobject                              2                         (   2)[LiCa]
    #     0002 dup
    #     0003 setlocal_WC_0                          a@0
    #     0005 leave                                                            (   3)[Re]
    #
    def setlocal_WC_0
      a = 2
    end

    def test_setlocal_WC_0
      jit.compile method(:setlocal_WC_0)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = setlocal_WC_0
      jit.disable!
      assert_equal 2, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
