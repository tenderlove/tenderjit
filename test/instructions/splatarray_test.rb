# frozen_string_literal: true

require "helper"

class TenderJIT
  class SplatarrayTest < JITTest
    # Disassembly (for v3.0.2):
    #
    #   == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,13)> (catch: FALSE)
    #   local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #   [ 1] a@0
    #   0000 newarray                               0                         (   1)[Li]
    #   0002 setlocal_WC_0                          a@0
    #   0004 getlocal_WC_0                          a@0
    #   0006 splatarray                             true
    #   0008 leave
    #
    def splat_empty_array
      a = []
      [*a]
    end

    def test_splatarray
      skip "Please implement splatarray!"

      jit.compile(method(:splat_empty_array))
      jit.enable!
      v = splat_empty_array
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [], v
    end
  end
end
