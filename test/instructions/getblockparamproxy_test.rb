# frozen_string_literal: true

require "helper"

class TenderJIT
  class GetblockparamproxyTest < JITTest
    def takes_symbol &blk
      blk.call 1
    end

    def test_getblockparamproxy_static_symbol
      assert_has_insn method(:takes_symbol), insn: :getblockparamproxy
      expected = takes_symbol(&:nil?)

      jit.compile(method(:takes_symbol))

      jit.enable!
      takes_symbol(&:nil?)
      actual = takes_symbol(&:nil?)
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end

    class Foo
      x = "omgomgomg"
      define_method :"omg#{x}?" do
        "cool"
      end
    end

    def takes_symbol2 m, &blk
      blk.call m
    end

    def test_getblockparamproxy_dynamic_symbol
      assert_has_insn method(:takes_symbol2), insn: :getblockparamproxy
      x = "omgomgomg"
      expected = takes_symbol2(Foo.new, &:"omg#{x}?")

      jit.compile(method(:takes_symbol2))

      jit.enable!
      takes_symbol2(Foo.new, &:"omg#{x}?")
      actual = takes_symbol2(Foo.new, &:"omg#{x}?")
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end

    def takes_iseq &blk
      blk.call
    end

    def test_getblockparamproxy_iseq
      assert_has_insn method(:takes_iseq), insn: :getblockparamproxy
      expected = takes_iseq { "foo" }

      jit.compile(method(:takes_iseq))

      jit.enable!
      takes_iseq { "foo" }
      actual = takes_iseq { "foo" }
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end
  end
end
