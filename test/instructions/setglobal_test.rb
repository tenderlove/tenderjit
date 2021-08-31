# frozen_string_literal: true

require "helper"

class TenderJIT
  class SetglobalTest < JITTest
    def set_debug val
      $foo = val
    end

    def test_setglobal
      $foo = true

      jit = TenderJIT.new
      jit.compile method(:set_debug)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = set_debug(false)
      jit.disable!
      assert_equal false, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
