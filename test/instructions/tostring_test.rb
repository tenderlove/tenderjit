# frozen_string_literal: true

require "helper"

class TenderJIT
  class TostringTest < JITTest
    def foo
      "#{111222333}"
    end

    def test_tostring
      jit.compile(method(:foo))
      jit.enable!
      v = foo
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal "111222333", v
    end
  end
end
