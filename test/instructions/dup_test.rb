# frozen_string_literal: true

require "helper"

class TenderJIT
  class DupTest < JITTest
    # Disassembly of the inner code (as of v3.1.0):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(3,3)> (catch: FALSE)
    #     0000 putself                                                          (   1)[Li]
    #     0001 opt_send_without_block                 <calldata!mid:a, argc:0, FCALL|VCALL|ARGS_SIMPLE>
    #     0003 dup
    #     0004 setlocal_WC_0                          _b@0
    #     0006 leave
    #
    def dup a
      _b = a
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
