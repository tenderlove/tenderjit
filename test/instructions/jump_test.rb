# frozen_string_literal: true

require "helper"

class TenderJIT
  class JumpTest < JITTest
    # Disassembly of the inner code (without catch table; as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,14)> (catch: FALSE)
    #     0000 jump                                   4                         (   1)[Li]
    #     0002 putnil
    #     0003 pop
    #     0004 putnil
    #     0005 nop
    #     0006 leave                                                            (   1)
    #
    def jump
      1 while false
    end

    # Only (absence of) side-effects can be tested, but it's not typical in this
    # project, so only exit/error-free execution is tested.
    #
    def test_jump
      jit.compile method(:jump)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = jump
      jit.disable!
      assert_nil v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
