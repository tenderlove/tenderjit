# frozen_string_literal: true

require "helper"

class TenderJIT
  class ExpandarrayTest < JITTest
    def expandarray list
      a, b = list
      [a, b]
    end

    def test_expandarray_not_embedded_long_enough
      expected = expandarray([1, 2, 3, 4])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray([1, 2, 3, 4])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_embedded_to_extended
      expected = expandarray([1, 2, 3, 4])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      # Heat the JIT with an embedded array
      expandarray([1, 2])

      # Call again with an extended array
      actual = expandarray([1, 2, 3, 4])

      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_extended_to_embedded
      expected = expandarray([1, 2])

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      # Heat the JIT with an extended array
      expandarray([1, 2, 3, 4])

      # Call again with an embedded array
      actual = expandarray([1, 2])

      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_heap_embedded_too_short
      skip "FIXME"
      expected = expandarray([1])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray([1])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_heap_embedded_long_enough
      expected = expandarray([1, 2])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray([1, 2])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_special
      skip "FIXME"
      expected = expandarray({a: 1, b: 2})

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray(true)
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
