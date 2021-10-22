# frozen_string_literal: true

require "helper"

class TenderJIT
  class PopTest < JITTest
    # == disasm: #<ISeq:<main>@x.rb:1 (1,0)-(8,3)> (catch: FALSE)
    # 0000 definemethod                           :one, one                 (   1)[Li]
    # 0003 definemethod                           :get_one, get_one         (   5)[Li]
    # 0006 putobject                              :get_one
    # 0008 leave

    # == disasm: #<ISeq:one@x.rb:1 (1,0)-(3,3)> (catch: FALSE)
    # 0000 putobject_INT2FIX_1_                                             (   2)[LiCa]
    # 0001 leave                                                            (   3)[Re]

    # == disasm: #<ISeq:get_one@x.rb:5 (5,0)-(8,3)> (catch: FALSE)
    # 0000 putself                                                          (   6)[LiCa]
    # 0001 opt_send_without_block                 <calldata!mid:one, argc:0, FCALL|VCALL|ARGS_SIMPLE>
    # 0003 pop
    # 0004 putself                                                          (   7)[Li]
    # 0005 opt_send_without_block                 <calldata!mid:one, argc:0, FCALL|VCALL|ARGS_SIMPLE>
    # 0007 leave                                                            (   8)[Re]
    def one
      1
    end

    def get_one
      one
      one
    end

    def test_pop
      m = method(:get_one)
      assert_has_insn m, insn: :pop
      jit.compile(m)
      jit.enable!
      v = m.call
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 1, v
    end
  end
end
