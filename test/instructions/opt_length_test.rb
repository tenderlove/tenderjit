# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptLengthTest < JITTest
    def string_length
      'true'.length
    end

    def test_opt_length_string
      setup_test_for(:string_length, 4)
    end

    def symbol_length
      :hey.length
    end

    def test_opt_length_symbol
      setup_test_for(:symbol_length, 3)
    end

    def array_length
      [1,2].length
    end

    def test_opt_length_array
      setup_test_for(:array_length, 2)
    end

    def hash_length
      { 'true' => 1 }.length
    end

    def test_opt_length_hash
      setup_test_for(:hash_length)
    end

    def setup_test_for(method_name, expected_length = 1)
      m = method(method_name)
      assert_has_insn m, insn: :opt_length
      jit.compile(m)
      jit.enable!
      v = m.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 1, jit.executed_methods
      assert_equal expected_length, v
    end
  end
end
