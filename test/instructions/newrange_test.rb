# frozen_string_literal: true

require "helper"

class TenderJIT
  class NewrangeTest < JITTest
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     0000 putstring                              "b"                       (   1)[Li]
    #     0002 setlocal_WC_0                          b@0
    #     0004 putstring                              "a"
    #     0006 getlocal_WC_0                          b@0
    #     0008 newrange                               0
    #     0010 leave
    #
    def new_range
      b = 'b'
      'a'..b
    end

    def test_newrange
      meth = method(:new_range)

      assert_has_insn meth, insn: :newrange

      jit.compile(meth)
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 'a'..'b', v
    end
  end
end
