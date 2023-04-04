# frozen_string_literal: true

require "helper"

class TenderJIT
  class NewarrayTest < JITTest
    def one; 1; end
    def two; 2; end
    def three; 3; end

    def empty_array
      []
    end

    def filled_array
      [one, two, three]
    end

    def test_empty_array
      compile(method(:empty_array), recv: self)
      jit.enable!
      v = empty_array
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [], v
    end

    def test_newarray_filled
      compile(method(:filled_array), recv: self)
      jit.enable!
      v = filled_array
      jit.disable!

      assert_equal 4, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [1, 2, 3], v
    end
  end
end
