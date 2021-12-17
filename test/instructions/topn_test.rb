# frozen_string_literal: true

require "helper"

class TenderJIT
  class TopnTest < JITTest
    # Disassembly (as of 3.0.2):
    #
    #   local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #   [ 1] arr@0
    #   0000 duparray                               [:foo, :bar, :baz]        (   2)[Li]
    #   0002 setlocal_WC_0                          arr@0
    #   0004 duparray                               [:qux, :sav]              (   3)[Li]
    #   0006 expandarray                            1, 0
    #   0009 getlocal_WC_0                          arr@0
    #   0011 putobject_INT2FIX_1_
    #   0012 topn                                   2
    #   0014 opt_aset                               <calldata!mid:[]=, argc:2, ARGS_SIMPLE>
    #   0016 pop
    #   0017 pop
    #   0018 getlocal_WC_0                          arr@0                     (   7)[Li]
    #   0020 leave
    #
    # Note the empty prefix string added.
    #
    def topn
      arr = [:foo, :bar, :baz]
      arr[1], = [:qux, :sav]

      # not necessary for the instruction to be genrated, but necesary for testing,
      # since the array assignment returns the rhs value.
      #
      arr
    end

    def test_topn
      meth = method(:topn)

      assert_has_insn meth, insn: :topn

      jit.compile(meth)
      jit.enable!
      v = meth.call
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [:foo, :qux, :baz], v
    end
  end
end
