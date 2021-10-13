# frozen_string_literal: true

require "helper"

class TenderJIT
  # The `checkkeyword` instruction requires the argument value not to be a constant.
  #
  class CheckkeywordTest < JITTest
    # Disassembly (with of 3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,40)> (catch: FALSE)
    #     0000 definemethod                           :mymeth, mymeth           (   1)[Li]
    #     0003 putself
    #     0004 putobject                              :foo
    #     0006 opt_send_without_block                 <calldata!mid:mymeth, argc:1, FCALL|ARGS_SIMPLE>
    #     0008 leave
    #
    #     == disasm: #<ISeq:mymeth@<compiled>:1 (1,1)-(1,26)> (catch: FALSE)
    #     local table (size: 2, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: 1@0, kwrest: -1])
    #     [ 2] x@0        [ 1] ?@1
    #     0000 checkkeyword                           3, 0                      (   1)
    #     0003 branchif                               9
    #     0005 newarray                               0
    #     0007 setlocal_WC_0                          x@0
    #     0009 getlocal_WC_0                          x@0[LiCa]
    #     0011 leave                                  [Re]
    #
    def with_argument
      def mymeth(x: [])
        x
      end

      mymeth(x: :foo)
    end

    # Disassembly (with of 3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,36)> (catch: FALSE)
    #     0000 definemethod                           :mymeth, mymeth           (   1)[Li]
    #     0003 putself
    #     0004 opt_send_without_block                 <calldata!mid:mymeth, argc:0, FCALL|ARGS_SIMPLE>
    #     0006 leave
    #
    #     == disasm: #<ISeq:mymeth@<compiled>:1 (1,1)-(1,26)> (catch: FALSE)
    #     local table (size: 2, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: 1@0, kwrest: -1])
    #     [ 2] x@0        [ 1] ?@1
    #     0000 checkkeyword                           3, 0                      (   1)
    #     0003 branchif                               9
    #     0005 newarray                               0
    #     0007 setlocal_WC_0                          x@0
    #     0009 getlocal_WC_0                          x@0[LiCa]
    #     0011 leave                                  [Re]
    #
    def with_default_argument
      def mymeth(x: [])
        x
      end

      mymeth
    end

    def test_checkkeyword_with_argument
      skip "Testing `checkkeyword` requires a `definemethod` implementation"

      meth = method(:with_argument)

      assert_has_insn meth, insn: :checkkeyword

      jit.compile meth

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      result = meth.call
      jit.disable!

      assert_equal(:foo, result)

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_checkkeyword_with_default_argument
      skip "Testing `checkkeyword` requires a `definemethod` implementation"

      meth = method(:with_default_argument)

      assert_has_insn meth, insn: :checkkeyword

      jit.compile meth

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      result = meth.call
      jit.disable!

      assert_equal([], result)

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
