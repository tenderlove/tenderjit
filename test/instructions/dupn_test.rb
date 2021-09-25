# frozen_string_literal: true

require "helper"

class TenderJIT
  class DupnTest < JITTest
    def omg peeks
      peeks[:foo] ||= :bar
    end

    def test_dupn
      obj = {}
      jit.compile(method(:omg))
      jit.enable!
      omg obj
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal :bar, obj[:foo]
    end
  end
end
