# frozen_string_literal: true

require "helper"

class TenderJIT
  class NopTest < JITTest
    # Simplified version of [Ruby 3.0.2's `nop` unit test](https://github.com/ruby/ruby/blob/0db68f023372b634603c74fca94588b457be084c/test/ruby/test_jit.rb#70).
    #
    # Disassembly of the inner code (without catch table; as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,17)> (catch: TRUE)
    #     0000 putnil                                                           (   1)[Li]
    #     0001 nop
    #     0002 leave
    #
    def nop
      nil rescue true
    end

    # Only (absence of) side-effects can be tested, but it's not typical in this
    # project, so only exit/error-free execution is tested.
    #
    def test_nop
      jit.compile method(:nop)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      nop
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
