# frozen_string_literal: true

require "helper"

class TenderJIT
  class TostringTest < JITTest
    # Disasm (as of 3.0.2):
    #
    #     0000 putobject                              ""                        (   1)[Li]
    #     0002 putobject                              :a
    #     0004 dup
    #     0005 opt_send_without_block                 <calldata!mid:to_s, argc:0, FCALL|ARGS_SIMPLE>
    #     0007 tostring
    #     0008 concatstrings                          2
    #     0010 leave
    #
    def tostring
      "#{:a}"
    end

    def test_tostring
      meth = method(:tostring)

      assert_has_insn meth, insn: :tostring

      jit.compile(meth)
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal "a", v
    end
  end
end
