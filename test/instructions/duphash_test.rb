# frozen_string_literal: true

require "helper"

class TenderJIT
  class DuphashTest < JITTest
    def duphash
      a = {a: 1, b: 2}
    end

    def test_duphash
      jit.compile method(:duphash)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = duphash
      jit.disable!
      assert_equal({a: 1, b: 2}, v)

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    ensure
      jit.uncompile method(:duphash)
    end
  end
end
