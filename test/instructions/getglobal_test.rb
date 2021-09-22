# frozen_string_literal: true

require "helper"

class TenderJIT
  class GetglobalTest < JITTest
    def check_debug
      $DEBUG
    end

    def test_getglobal
      jit.compile method(:check_debug)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = check_debug
      jit.disable!
      assert_equal $DEBUG, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
