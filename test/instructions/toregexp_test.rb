# frozen_string_literal: true

require "helper"

class TenderJIT
  class ToregexpTest < JITTest
    # Disassembly (as of 3.0.2):
    #
    #     0000 putobject                              ""                        (   1)[Li]
    #     0002 putobject                              :foo
    #     0004 dup
    #     0005 opt_send_without_block                 <calldata!mid:to_s, argc:0, FCALL|ARGS_SIMPLE>
    #     0007 tostring
    #     0008 toregexp                               0, 2
    #     0011 leave
    #
    # Note the empty prefix string added.
    #
    def regexp_single_expression
      /#{:foo}/
    end

    # Disassembly (as of 3.0.2):
    #
    #     0000 putobject                              :foo                      (   1)[Li]
    #     0002 dup
    #     0003 opt_send_without_block                 <calldata!mid:to_s, argc:0, FCALL|ARGS_SIMPLE>
    #     0005 tostring
    #     0006 putobject                              :bar
    #     0008 dup
    #     0009 opt_send_without_block                 <calldata!mid:to_s, argc:0, FCALL|ARGS_SIMPLE>
    #     0011 tostring
    #     0012 putobject                              :sav
    #     0014 dup
    #     0015 opt_send_without_block                 <calldata!mid:to_s, argc:0, FCALL|ARGS_SIMPLE>
    #     0017 tostring
    #     0018 toregexp                               0, 3
    #     0021 leave
    #
    def regexp_multi_expression
      /#{:foo}#{:bar}#{:sav}/
    end

    def test_toregexp_single_expression
      meth = method(:regexp_single_expression)

      assert_has_insn meth, insn: :toregexp

      jit.compile(meth)
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal (/foo/), v
    end

    def test_toregexp_multi_expression
      meth = method(:regexp_multi_expression)

      assert_has_insn meth, insn: :toregexp

      jit.compile(meth)
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal (/foobarsav/), v
    end
  end
end
