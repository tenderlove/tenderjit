# frozen_string_literal: true

require "helper"

class TenderJIT
  class PutnilTest < JITTest
    def putnil
      nil
    end

    def test_putnil
      v = assert_jit method(:putnil), compiled: 1, executed: 1, exits: 0
      assert_nil v
    end
  end
end
