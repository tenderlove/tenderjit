# frozen_string_literal: true

require "helper"

class TenderJIT
  class SwapTest < JITTest
    def method_with_swap
      defined?([[]])
    end

    def test_swap
      m = method(:method_with_swap)

      assert_has_insn m, insn: :swap

      jit.compile(m)
      jit.enable!
      v = m.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal "expression", v
    end

    class Thing
      attr_reader :m

      def initialize
        @m = :hi
      end

      def write= m
        @m = m
      end
    end

    def topswap thing
      _, thing.write = :foo
    end

    def test_topswap
      m = method(:topswap)

      thing = Thing.new
      expected = topswap(thing)

      thing2 = Thing.new

      jit.compile(m)
      jit.enable!
      actual = topswap(thing2)
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
      assert_nil thing.m
      assert_nil thing2.m
    end
  end
end
