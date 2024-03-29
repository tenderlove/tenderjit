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

    def thing param; param; end

    def test_aref_with_method
      m = method(:thing)
      expected = aref(m, "something")

      jit.compile method(:aref)

      jit.enable!
      actual = aref(m, "something")
      jit.disable!

      assert_equal expected, actual
      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_opt_aref
      compile method(:aref), recv: self

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

    def test_opt_aref_does_not_crash
      @peeks = {}
      jit.compile method(:add_mappings)
      jit.enable!
      add_mappings(Object.new)
      add_mappings(Object.new)
      add_mappings(Object.new)
      jit.enable!
    end

    def numeric_aref a, b
      a[b]
    end

    def test_opt_aref_numeric
      expected = numeric_aref(1, 0)

      jit.compile method(:numeric_aref)

      jit.enable!
      numeric_aref(1, 0)
      v = numeric_aref(1, 0)
      jit.disable!

      assert_equal expected, v
      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    private

    def add_mappings(peek)
      # filter the logically equivalent objects
      @peeks[peek] ||= peek
    end
  end
end
