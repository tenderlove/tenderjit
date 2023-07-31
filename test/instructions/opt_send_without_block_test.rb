# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptSendWithoutBlockTest < JITTest
    def fun a, b
      a < b
    end

    def call_function_simple
      fun(1, 2)
    end

    def test_method_call
      compile method(:call_function_simple), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_function_simple
      jit.disable!
      assert_equal true, v

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_function_simple
      jit.disable!
      assert_equal true, v

      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    alias :old_p :p
    alias :old_p2 :p
    alias :old_p3 :p

    def call_p
      !"lol"
      :foo
    end

    alias :mm :call_p

    def test_call_p
      compile method(:call_p), recv: self
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_p
      jit.disable!
      assert_equal :foo, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def call_bang
      !"lol"
      :foo
    end

    def test_call_bang
      jit.compile method(:call_bang)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = call_bang
      jit.disable!
      assert_equal :foo, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def one
      three
      :lol
    end

    def three
      !"lol"
    end

    def test_deep_exit
      jit.compile method(:one)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = one
      jit.disable!
      assert_equal :lol, v

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def cfunc x
      Fiddle.dlwrap x
    end

    def test_cfunc
      obj = Object.new
      expected = Fiddle.dlwrap obj

      compile(method(:cfunc), recv: self)

      jit.enable!
      cfunc(obj)
      v = cfunc(obj)
      jit.disable!
      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal expected, v
    end

    define_method :bmethod do |a, b|
      a + b
    end

    def call_bmethod
      bmethod(1, 2)
    end

    def test_call_bmethod
      v = assert_jit method(:call_bmethod), compiled: 2, executed: 2, exits: 0
      assert_equal 3, v
    end

    def test_call_bmethod_twice
      jit.compile method(:call_bmethod)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      call_bmethod
      v = call_bmethod
      jit.disable!
      assert_equal 3, v

      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class A; end

    def wow m
      m.foo
    end

    def wow2 m
      m.foo(m)
    end

    def test_subclass_bmethod
      x = Class.new(A) {
        define_method(:foo) { self }
      }

      x1 = x.new
      x2 = x.new

      jit.compile method(:wow)

      jit.enable!
      v1 = wow(x1)
      v2 = wow(x2)
      jit.disable!

      assert_same x1, v1
      assert_same x2, v2

      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class B
      def initialize
        @omg = Class.new {
          attr_reader :x

          def initialize x
            @x = x
          end
        }
      end

      def foo m
        @omg.new self
      end
    end

    def test_iseq_self
      x1 = B.new
      x2 = B.new
      x3 = B.new

      jit.compile method(:wow2)

      jit.enable!
      v1 = wow2(x1)
      v2 = wow2(x2)
      v3 = wow2(x3)
      jit.disable!

      assert_same x1, v1.x
      assert_same x2, v2.x
      assert_same x3, v3.x

      assert_equal 2, jit.compiled_methods
      assert_equal 6, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class PMA; def foo; "a"; end; end
    class PMB; def foo; "b"; end; end

    def polymorphic_iseq x
      x.foo
    end

    def test_polymorphic_iseq
      a = PMA.new
      b = PMB.new

      compile method(:polymorphic_iseq), recv: self
      jit.enable!
      v1 = polymorphic_iseq a
      v2 = polymorphic_iseq b
      v2 = polymorphic_iseq b
      jit.disable!

      assert_equal "a", v1
      assert_equal "b", v2
      assert_equal 3, jit.compiled_methods
      assert_equal 6, jit.executed_methods
      assert_equal 0, jit.exits
    end

    class PM2A; def foo(m); 1 + m; end; end
    class PM2B; def foo(m); 2 + m; end; end

    def polymorphic_iseq_param x, z
      x.foo(z)
    end

    def test_polymorphic_param_iseq
      a = PM2A.new
      b = PM2B.new
      c = 3

      compile method(:polymorphic_iseq_param), recv: self
      jit.enable!
      v1 = polymorphic_iseq_param a, c
      v2 = polymorphic_iseq_param b, c
      v3 = polymorphic_iseq_param b, c
      jit.disable!

      assert_equal 4, v1
      assert_equal 5, v2
      assert_equal 5, v3
      assert_equal 3, jit.compiled_methods
      assert_equal 6, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def polymorphic x
      x.is_a?(Integer)
    end

    def test_isa
      obj = Object.new
      polymorphic obj # heat cache

      compile method(:polymorphic), recv: self
      jit.enable!
      v1 = polymorphic obj
      v2 = polymorphic obj
      v3 = polymorphic obj
      polymorphic obj
      polymorphic obj
      polymorphic obj
      v7 = polymorphic 4
      jit.disable!

      refute v1
      refute v2
      refute v3
      assert v7
      assert_equal 1, jit.compiled_methods
      assert_equal 7, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_isa_specialize_nil
      jit.compile method(:polymorphic)
      jit.enable!
      # Heat
      polymorphic nil
      polymorphic nil
      polymorphic nil
      v1 = polymorphic nil
      # Test
      v2 = polymorphic 1
      jit.disable!

      refute v1
      assert v2
    end

    def test_isa_specialize_false
      jit.compile method(:polymorphic)
      jit.enable!
      # Heat
      polymorphic false
      polymorphic false
      polymorphic false
      v1 = polymorphic false
      # Test
      v2 = polymorphic 1
      jit.disable!

      refute v1
      assert v2
    end

    def get_next_float x
      x.next_float
    rescue NoMethodError
      :nope
    end

    def test_isa_specialize_immediate
      float = 3.2
      int = 1
      float_expected = get_next_float(float)
      int_expected = get_next_float(int)

      jit.compile method(:get_next_float)
      jit.enable!
      # Heat
      get_next_float float
      get_next_float float
      get_next_float float
      v1 = get_next_float float
      # Test
      v2 = get_next_float int
      jit.disable!

      assert_equal float_expected, v1
      assert_equal int_expected, v2
    end

    class Thing
      def is_a? m
        :omg
      end
    end

    class OtherThing
      def is_a? m
        :lol
      end
    end

    def is_a_thing x
      x.is_a?(Thing)
    end

    def test_isa_specialize_class_non_immediates
      a = Object.new
      b = Thing.new
      a_expected = is_a_thing(a)
      b_expected = is_a_thing(b)

      jit.compile method(:is_a_thing)
      jit.enable!
      # Heat
      is_a_thing a
      is_a_thing a
      is_a_thing a
      is_a_thing a
      a_actual = is_a_thing a
      # Test
      b_actual = is_a_thing b
      jit.disable!

      assert_equal a_expected, a_actual
      assert_equal b_expected, b_actual
    end

    def test_specialize_class_iseq_methods
      a = OtherThing.new
      b = Thing.new
      a_expected = is_a_thing(a)
      b_expected = is_a_thing(b)

      jit.compile method(:is_a_thing)
      jit.enable!
      # Heat
      is_a_thing a
      is_a_thing a
      is_a_thing a
      is_a_thing a
      a_actual = is_a_thing a
      # Test
      b_actual = is_a_thing b
      jit.disable!

      assert_equal a_expected, a_actual
      assert_equal b_expected, b_actual
    end

    class HasReader
      attr_reader :foo

      def initialize
        @foo = :hi
      end
    end

    def call_reader x
      x.foo
    end

    def test_attr_reader
      instance = HasReader.new
      expected = call_reader instance

      jit.compile method(:call_reader)
      jit.enable!
      actual = call_reader instance
      jit.disable!

      assert_equal expected, actual
      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def swap a, b
      [b, a]
    end

    def call_splat list
      swap(*list)
    end

    def test_splat
      list = [1, 2]
      expected = call_splat(list)

      jit.compile method(:call_splat)
      jit.enable!
      actual = call_splat(list)
      jit.disable!

      assert_equal expected, actual
      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_splat_extended
      # Make an extended array
      list = [1, 2, 3, 4, 5]

      # Shifting down won't convert it back to "embedded"
      3.times { list.shift }

      refute Ruby.new.embedded_array?(Fiddle.dlwrap(list))
      expected = call_splat(list)

      jit.compile method(:call_splat)
      jit.enable!
      actual = call_splat(list)
      jit.disable!

      assert_equal expected, actual
      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_heat_embed_switch_to_extend
      list = [1, 2]
      expected = call_splat(list)

      # Make an extended array
      list2 = [1, 2, 3, 4, 5]

      # Shifting down won't convert it back to "embedded"
      3.times { list2.pop }
      refute Ruby.new.embedded_array?(Fiddle.dlwrap(list2))

      jit.compile method(:call_splat)
      jit.enable!
      call_splat(list)
      actual = call_splat(list2)
      jit.disable!

      assert_equal expected, actual
      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_heat_extend_switch_to_embed
      list = [1, 2]

      # Make an extended array
      list2 = [1, 2, 3, 4, 5]

      # Shifting down won't convert it back to "embedded"
      3.times { list2.pop }

      expected = call_splat(list2)

      compile method(:call_splat), recv: self
      jit.enable!
      call_splat(list2)
      actual = call_splat(list)
      jit.disable!

      assert_equal expected, actual
      assert_equal 2, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_heat_embed_size_changes
      list = [1, 2]
      jit.compile method(:call_splat)
      jit.enable!
      call_splat(list)
      assert_raises(ArgumentError) { call_splat([4, 5, 6]) }
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 3, jit.executed_methods
      assert_equal 1, jit.exits
    end

    def use_send
      send :fun, 1, 2
    end

    def test_optimized_send
      expected = use_send
      jit.compile method(:use_send)
      jit.enable!
      actual = use_send
      jit.disable!

      assert_equal expected, actual
      assert_equal 0, jit.exits
      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
    end

    def use_send_splat list
      send :swap, *list
    end

    def test_optimized_send_splat
      list = [1, 2]
      expected = use_send_splat(list)
      jit.compile method(:use_send_splat)
      jit.enable!
      actual = use_send_splat(list)
      jit.disable!

      assert_equal expected, actual
      assert_equal 0, jit.exits
      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
    end

    def splat_all list
      send(*list)
    end

    def identity list
      list
    end

    def test_splat_all
      list = [:use_send_splat, [1, 2]]
      expected = splat_all(list)
      jit.compile method(:splat_all)
      jit.enable!
      actual = splat_all(list)
      jit.disable!

      assert_equal expected, actual
      assert_equal 0, jit.exits
      assert_equal 3, jit.compiled_methods
      assert_equal 3, jit.executed_methods
    end

    def test_splat_all_invalidate_name
      list = [:use_send_splat, [1, 2]]
      list2 = [:identity, [1, 2]]
      expected = splat_all(list2)
      jit.compile method(:splat_all)
      jit.enable!
      # heat with list
      splat_all(list)
      splat_all(list)
      splat_all(list)
      actual = splat_all(list2)
      jit.disable!

      assert_equal expected, actual
      assert_equal 0, jit.exits
      assert_equal 4, jit.compiled_methods
      assert_equal 11, jit.executed_methods
    end

    def extended a, b, c, d, e
      a + b + c + d + e
    end

    def extended2 a, b, c, d, e
      2 + a + b + c + d + e
    end

    def test_splat_all_invalidate_name_extended
      list = [:extended, 1, 2, 3, 4, 5]
      list2 = [:extended2, 1, 3, 3, 4, 5]
      expected = splat_all(list2)
      jit.compile method(:splat_all)
      jit.enable!
      # heat with list
      splat_all(list)
      splat_all(list)
      splat_all(list)
      actual = splat_all(list2)
      jit.disable!

      assert_equal expected, actual
      assert_equal 0, jit.exits
      assert_equal 3, jit.compiled_methods
      assert_equal 8, jit.executed_methods
    end

    def uno; 1; end
    def dos; 2; end

    def call_send_with_name name
      send name
    end

    # Fix this test.  We're not properly invalidating when
    # the method name changes at the call site
    def test_send_invalidates_on_name
      expected = call_send_with_name(:uno)
      jit.compile method(:call_send_with_name)
      jit.enable!
      # heat with two
      call_send_with_name(:dos)
      call_send_with_name(:dos)
      call_send_with_name(:dos)
      actual = call_send_with_name(:uno)
      jit.disable!

      assert_equal expected, actual
      assert_equal 0, jit.exits
      assert_equal 3, jit.compiled_methods
      assert_equal 8, jit.executed_methods
    end
  end
end
