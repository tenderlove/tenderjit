# frozen_string_literal: true

require "helper"

class TenderJIT
  class ConcatarrayTest < JITTest
    # Disasm (as of 3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,14)> (catch: FALSE)
    #     0000 duparray                               [:foo]                    (   1)[Li]
    #     0002 putobject                              :bar
    #     0004 concatarray
    #     0005 leave
    #
    def concatarray
      [:foo, *:bar]
    end

    def test_concatarray
      meth = method(:concatarray)

      assert_has_insn meth, insn: :concatarray

      jit.compile(meth)
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [:foo, :bar], v
    end

    # See https://github.com/ruby/ruby/blob/v3_0_2/vm_insnhelper.c#L4144.
    #
    def test_concatarray_with_dup
      skip "Please implement concatarray dup case!"
    end
  end
end
