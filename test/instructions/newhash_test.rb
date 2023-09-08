require "helper"

class TenderJIT
  class NewhashTest < JITTest
    def empty_hash
      {}
    end

    def filled_hash
      {a: 2, b: 'something'}
    end

    def test_empty_hash
      assert_has_insn method(:empty_hash), insn: :newhash

      compile(method(:empty_hash), recv: self)
      jit.enable!
      v = empty_hash
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal Hash[], v
    end

    def test_filled_hash
      assert_has_insn method(:filled_hash), insn: :newhash
      compile(method(:filled_hash), recv: self)
      jit.enable!
      v = filled_hash
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 1, jit.executed_methods
      assert_equal Hash[a: 2, b: 'something'], v
    end
  end
end
