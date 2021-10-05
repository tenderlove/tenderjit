require "helper"

class TenderJIT
  class PutstringTest < JITTest

    # == disasm: #<ISeq:foo@x.rb:1 (1,0)-(3,3)> (catch: FALSE)
    # 0000 putstring                              "hello, world"            (   2)[LiCa]
    # 0002 leave                                                            (   3)[Re]
    def foo
      "hello, world"
    end

    def test_putstring
      m = method(:foo)
      assert_has_insn m, insn: :putstring

      jit.compile(method(:foo))
      jit.enable!
      v = foo
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal "hello, world", v
    end
  end
end
