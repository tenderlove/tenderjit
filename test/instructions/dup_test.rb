# frozen_string_literal: true

require "helper"

class TenderJIT
  class DupTest < JITTest
    # Disassembly of the inner code (as of v3.1.0):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(3,3)> (catch: FALSE)
    #     0000 getlocal_WC_0                          a@0                       (   2)[LiCa]
    #     0002 dup
    #     0003 setlocal_WC_0                          b@1
    #     0005 leave                                                            (   3)[Re]
    #
    def dup a
      b = a
    end

    def test_dup
      jit.compile(method(:dup))
      jit.enable!
      res = dup "something"
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal "something", res
    end
  end
end
