# frozen_string_literal: true

require "helper"

class TenderJIT
  class PutobjectInt2fix0Test < JITTest
    def zero
      0
    end

    def test_putobject_INT2FIX_0_
      v = assert_jit method(:zero), compiled: 1, executed: 1, exits: 0
      assert_equal 0, v
    end
  end
end
