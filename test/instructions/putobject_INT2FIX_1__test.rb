# frozen_string_literal: true

require "helper"

class TenderJIT
  class PutobjectInt2fix1Test < JITTest
    def one
      1
    end

    def test_putobject_INT2FIX_1_
      v = assert_jit method(:one), compiled: 1, executed: 1, exits: 0
      assert_equal 1, v
    end
  end
end
