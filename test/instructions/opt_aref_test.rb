# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptArefTest < JITTest
    def aref obj, key
      obj[key]
    end

    def test_has_opt_aref
      assert_has_insn method(:aref), insn: :opt_aref
    end

    def test_opt_aref
      jit.compile method(:aref)

      jit.enable!
      v = aref([1, 2, 3], 2)
      jit.disable!

      assert_equal 3, v
      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_opt_aref_twice
      jit.compile method(:aref)

      jit.enable!
      aref([1, 2, 3], 2)
      v = aref([1, 2, 3], 2)
      jit.disable!

      assert_equal 3, v
      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_opt_aref_hash
      jit.compile method(:aref)

      jit.enable!
      v = aref({ 2 => :hello }, 2)
      jit.disable!

      assert_equal :hello, v
      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_hash_then_array
      jit.compile method(:aref)

      jit.enable!
      v1 = aref({ 2 => :hello }, 2)
      v2 = aref([1, 2, 3], 2)
      jit.disable!

      assert_equal :hello, v1
      assert_equal 3, v2
      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_hash_then_array_twice
      jit.compile method(:aref)

      jit.enable!
      aref({ 2 => :hello }, 2)
      aref([1, 2, 3], 2)
      v1 = aref({ 2 => :hello }, 2)
      v2 = aref([1, 2, 3], 2)
      jit.disable!

      assert_equal :hello, v1
      assert_equal 3, v2
      assert_equal 1, jit.compiled_methods
      assert_equal 4, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
