# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptGetConstantPathTest < JITTest
    def getconst
      # If getconstantpath is the first instruction, RJIT will invalidate
      # the code.
      a = 1
      Fiddle
    end

    def test_opt_getconstant_path
      compile(method(:getconst), recv: self)
      assert_equal 0, jit.exits

      val = nil
      jit.enable!
      getconst # exit
      getconst # re-enter
      getconst
      getconst
      val = getconst
      jit.disable!

      assert_equal Fiddle, val
      assert_equal 1, jit.exits
      assert_equal 1, jit.compiled_methods
      assert_equal 5, jit.executed_methods
    end
  end
end
