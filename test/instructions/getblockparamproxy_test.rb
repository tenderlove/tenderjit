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

      compile(method(:takes_symbol), recv: self)

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

      compile(method(:takes_symbol2), recv: self)

      jit.enable!
      takes_symbol2(Foo.new, &:"omg#{x}?")
      actual = takes_symbol2(Foo.new, &:"omg#{x}?")
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end

    def calls_with_params &blk
      blk.call(1, 2)
    end

    def test_getblockparamproxy_iseq_params
      assert_has_insn method(:takes_iseq), insn: :getblockparamproxy
      expected = calls_with_params { |a, b| a + b }

      compile(method(:calls_with_params), recv: self)

      jit.enable!
      calls_with_params { |a, b| a + b }
      actual = calls_with_params { |a, b| a + b }
      jit.disable!

      assert_equal expected, actual
      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
    end

    def takes_iseq &blk
      blk.call
    end

    def test_getblockparamproxy_iseq
      assert_has_insn method(:takes_iseq), insn: :getblockparamproxy
      expected = takes_iseq { "foo" }

      compile(method(:takes_iseq), recv: self)

      jit.enable!
      takes_iseq { "foo" }
      actual = takes_iseq { "foo" }
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end

    def takes_nil &blk
      blk.call if blk
    end

    def test_getblockparamproxy_nil
      assert_has_insn method(:takes_iseq), insn: :getblockparamproxy
      expected = takes_nil

      compile(method(:takes_nil), recv: self)

      jit.enable!
      takes_nil
      actual = takes_nil
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_nil actual
    end
  end
end
