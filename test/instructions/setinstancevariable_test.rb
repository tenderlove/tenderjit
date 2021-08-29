# frozen_string_literal: true

require "helper"

class TenderJIT
  class SetinstancevariableTest < JITTest
    class Foo
      attr_reader :a

      def initialize
        @a = "a"
      end
    end

    def test_setinstancevariable
      jit = TenderJIT.new
      jit.compile(Foo.instance_method(:initialize))
      assert_equal 0, jit.executed_methods
      jit.enable!
      foo = Foo.new
      jit.disable!
      assert_equal "a", foo.a
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    ensure
      jit.uncompile(Foo.instance_method(:initialize))
    end

    class Extended
      attr_reader :a, :b, :c, :d

      def initialize
        @a = "a"
        @b = "b"
        @c = "c"
        @d = "d"
      end
    end

    def test_setinstancevariable_extended
      jit = TenderJIT.new
      jit.compile(Extended.instance_method(:initialize))
      assert_equal 0, jit.executed_methods
      jit.enable!
      extended = Extended.new
      jit.disable!
      assert_equal "a", extended.a
      assert_equal "b", extended.b
      assert_equal "c", extended.c
      assert_equal "d", extended.d
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    ensure
      jit.uncompile(Foo.instance_method(:initialize))
    end
  end
end
