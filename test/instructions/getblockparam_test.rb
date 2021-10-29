# frozen_string_literal: true

require "helper"

class TenderJIT
  class GetblockparamTest < JITTest
    def takes_symbol &blk
      m = nil
      [1, 1].each do
        m = blk.call 1
      end
      m
    end

    def test_getblockparam_symbol
      assert_has_insn method(:takes_symbol), insn: :getblockparam

      expected = takes_symbol(&:nil?)

      jit.compile(method(:takes_symbol))

      jit.enable!
      actual = takes_symbol(&:nil?)
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end
  end
end
