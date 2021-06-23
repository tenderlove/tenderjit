require "helper"
require "tendertools/ruby_internals"

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
  end
end
