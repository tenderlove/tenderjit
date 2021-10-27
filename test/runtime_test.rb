# frozen_string_literal: true

require "helper"

class TenderJIT
  class RuntimeTest < Test
    attr_reader :rt

    def setup
      super

      fisk = Fisk.new
      buffer = StringIO.new
      temp_stack = TempStack.new

      @rt = Runtime::new(fisk, buffer, temp_stack)
    end

    # Smoke test.
    #
    def test_if_eq_imm_imm64
      @rt.if_eq(2 << 0, 2 << 32)
    end

    # Smoke test.
    #
    def test_if_eq_imm_immnot64
      @rt.if_eq(2 << 0, 2 << 0)
    end

    # See https://github.com/tenderlove/tenderjit/issues/35#issuecomment-934872857
    #
    # > The code in main is emitting an extra mov instruction because the lhs is
    # > an immediate when we could have put the lhs in the rhs and directly used
    # > the CMP instruction.
    #
    # When tackling, update all the invocations, then turn the swap into an
    # assertion.
    #
    def test_if_eq_imm_not_imm
      skip "Optimize the if_eq invocations"
    end

    def test_inc
      @rt.inc Fisk::Registers::RAX
      buffer = @rt.write!

      assert_equal buffer.string, "H\xFF\xC0"
    end
  end # class RuntimeTest
end
