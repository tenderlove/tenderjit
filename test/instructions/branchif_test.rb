# frozen_string_literal: true

require "helper"

class TenderJIT
  class BranchIfTest < JITTest
    # Simplified version of [Ruby 3.0.2's `branchif` unit test](https://github.com/ruby/ruby/blob/0db68f023372b634603c74fca94588b457be084c/test/ruby/test_jit.rb#L459).
    #
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,20)> (catch: FALSE)
    #     == catch table
    #     | catch type: break  st: 0008 ed: 0013 sp: 0000 cont: 0013
    #     | catch type: next   st: 0008 ed: 0013 sp: 0000 cont: 0007
    #     | catch type: redo   st: 0008 ed: 0013 sp: 0000 cont: 0008
    #     |------------------------------------------------------------------------
    #     local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #     [ 1] a@0
    #     0000 putobject                              false                     (   1)[Li]
    #     0002 setlocal_WC_0                          a@0
    #     0004 jump                                   8
    #     0006 putnil
    #     0007 pop
    #     0008 getlocal_WC_0                          a@0
    #     0010 branchif                               8
    #     0012 putnil
    #     0013 nop
    #     0014 leave                                                            (   1)
    #
    def branch_not_taken
      a = false
      1 while a
    end

    # Modified version of `branch_not_taken`, with branching taking place.
    #
    # The code doesn't make much sense in itself, however, `while` is what the
    # current Ruby UT uses, so it makes sense to use it as reference.
    #
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,26)> (catch: FALSE)
    #     == catch table
    #     | catch type: break  st: 0010 ed: 0017 sp: 0000 cont: 0017
    #     | catch type: next   st: 0010 ed: 0017 sp: 0000 cont: 0007
    #     | catch type: redo   st: 0010 ed: 0017 sp: 0000 cont: 0010
    #     |------------------------------------------------------------------------
    #     local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #     [ 1] a@0
    #     0000 putobject                              true                      (   1)[Li]
    #     0002 setlocal_WC_0                          a@0
    #     0004 jump                                   12
    #     0006 putnil
    #     0007 pop
    #     0008 jump                                   12
    #     0010 putobject_INT2FIX_1_
    #     0011 leave                                  [Re]
    #     0012 getlocal_WC_0                          a@0
    #     0014 branchif                               10
    #     0016 putnil
    #     0017 nop
    #     0018 leave                                                            (   1)
    #
    def branch_taken
      a = true
      return 1 while a
    end

    def test_branch_not_taken
      jit.compile method(:branch_not_taken)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = branch_not_taken
      jit.disable!
      assert_nil v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_branch_taken
      jit.compile method(:branch_taken)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = branch_taken
      jit.disable!
      assert_equal 1, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
