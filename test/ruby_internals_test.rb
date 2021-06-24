require "helper"
require "tendertools/ruby_internals"
require "fiddle/import"

module TenderTools
  class RubyInternalsTest < Test
    def test_qfalse
      assert_equal 0, TenderTools::RubyInternals::CONSTANTS["RUBY_Qfalse"]
    end

    def test_RUBY_T_
      assert_equal 0, c("RUBY_T_NONE")
      assert_equal 1, c("RUBY_T_OBJECT")
      assert_equal 2, c("RUBY_T_CLASS")
      assert_equal 3, c("RUBY_T_MODULE")
      assert_equal 4, c("RUBY_T_FLOAT")
      assert_equal 5, c("RUBY_T_STRING")
      assert_equal 6, c("RUBY_T_REGEXP")
      assert_equal 7, c("RUBY_T_ARRAY")
      assert_equal 8, c("RUBY_T_HASH")
      assert_equal 9, c("RUBY_T_STRUCT")
      assert_equal 10, c("RUBY_T_BIGNUM")
      assert_equal 11, c("RUBY_T_FILE")
      assert_equal 12, c("RUBY_T_DATA")
      assert_equal 13, c("RUBY_T_MATCH")
      assert_equal 14, c("RUBY_T_COMPLEX")
      assert_equal 15, c("RUBY_T_RATIONAL")
      assert_equal 17, c("RUBY_T_NIL")
      assert_equal 18, c("RUBY_T_TRUE")
      assert_equal 19, c("RUBY_T_FALSE")
      assert_equal 20, c("RUBY_T_SYMBOL")
      assert_equal 21, c("RUBY_T_FIXNUM")
      assert_equal 22, c("RUBY_T_UNDEF")
      assert_equal 26, c("RUBY_T_IMEMO")
      assert_equal 27, c("RUBY_T_NODE")
      assert_equal 28, c("RUBY_T_ICLASS")
      assert_equal 29, c("RUBY_T_ZOMBIE")
      assert_equal 30, c("RUBY_T_MOVED")
      assert_equal 31, c("RUBY_T_MASK")
    end

    def c name
      TenderTools::RubyInternals::CONSTANTS[name]
    end

    class Foo; end

    class ClassWithIvars
      def initialize
        @a = "hello"
        @b = "world"
        @c = "neat"
      end
    end

    def test_RBasic
      rBasic = TenderTools::RubyInternals::GC["RBasic"]
      assert_rBasic rBasic

      # Test we can extract the class from an rBasic
      foo = Foo.new
      wrapper = rBasic.new(Fiddle.dlwrap(foo))
      assert_equal Foo, Fiddle.dlunwrap(wrapper.klass)
    end

    def test_RObject
      rObject = TenderTools::RubyInternals::GC["RObject"]

      assert_equal ["basic", "as"], rObject.members.map(&:first)

      assert_rBasic rObject.types.first

      # RObject union
      rObject_as = rObject.types.last

      case rObject_as.members
      in [[heap, _], ary]
        assert_equal "heap", heap
        assert_equal "ary", ary
      else
        flunk
      end

      # Check the "heap" member. It's a struct
      rObject_as_heap = rObject_as.types.first
      assert_equal ["numiv", "ivptr", "iv_index_tbl"], rObject_as_heap.members
      assert_equal [-Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], rObject_as_heap.types

      # Check the "ary" member. It's an array of unsigned long
      assert_equal [-Fiddle::TYPE_LONG, 3], rObject_as.types.last
    end

    def test_read_RObject_ivars
      rObject = TenderTools::RubyInternals::GC["RObject"]

      obj = ClassWithIvars.new
      ptr = rObject.new Fiddle.dlwrap obj

      assert_equal "hello", Fiddle.dlunwrap(ptr.as.ary[0])
      assert_equal "world", Fiddle.dlunwrap(ptr.as.ary[1])
      assert_equal "neat", Fiddle.dlunwrap(ptr.as.ary[2])
    end

    def assert_rBasic rBasic
      assert_equal [-Fiddle::TYPE_LONG, -Fiddle::TYPE_LONG], rBasic.types
      assert_equal ["flags", "klass"], rBasic.members
    end
  end
end
