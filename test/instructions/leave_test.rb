# frozen_string_literal: true

require "helper"

class TenderJIT
  class LeaveTest < JITTest
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,0)> (catch: FALSE)
    #     0000 putnil                                                           (   1)
    #     0001 leave
    #
    def leave; end

    # Only (absence of) side-effects can be tested, but it's not typical in this
    # project, so only exit/error-free execution is tested.
    #
    def test_leave
      jit.compile method(:leave)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = leave
      jit.disable!
      assert_nil v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
