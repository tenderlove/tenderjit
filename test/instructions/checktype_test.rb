# frozen_string_literal: true

require "helper"

class TenderJIT
  class ChecktypeTest < JITTest
    def string
      "foo"
    end

    def interpolation
      "foo #{string}"
    end

    def test_checktype
      m = method(:interpolation)
      iseq = RubyVM::InstructionSequence.of(m)
      assert_includes iseq.to_a.flatten, :checktype

      jit = TenderJIT.new
      jit.compile m
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      v = interpolation
      jit.disable!
      assert_equal "foo foo", v

      assert_equal 2, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
