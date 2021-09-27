# frozen_string_literal: true

require "helper"

class TenderJIT
  class BranchnilTest < JITTest
    # Simplified version of [Ruby 3.0.2's `branchnil` unit test](https://github.com/ruby/ruby/blob/0db68f023372b634603c74fca94588b457be084c/test/ruby/test_jit.rb#L479).
    #
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,14)> (catch: FALSE)
    #     local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #     [ 1] a@0
    #     0000 putobject                              2                         (   1)[Li]
    #     0002 setlocal_WC_0                          a@0
    #     0004 getlocal_WC_0                          a@0
    #     0006 dup
    #     0007 branchnil                              12
    #     0009 putobject_INT2FIX_1_
    #     0010 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
    #     0012 leave
    #
    def branch_not_taken
      a = 2
      a&.+(1)
    end

    # Modified version of `branch_not_taken`, with branching taking place.
    #
    # The code doesn't make much sense in itself, however, `while` is what the
    # current Ruby UT uses, so it makes sense to use it as reference.
    #
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,16)> (catch: FALSE)
    #     local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #     [ 1] a@0
    #     0000 putnil                                                           (   1)[Li]
    #     0001 setlocal_WC_0                          a@0
    #     0003 getlocal_WC_0                          a@0
    #     0005 dup
    #     0006 branchnil                              11
    #     0008 putobject_INT2FIX_1_
    #     0009 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
    #     0011 leave
    #
    def branch_taken
      a = nil
      a&.+(1)
    end

    def test_branch_not_taken
      skip "Please implement branchnil!"

      jit.compile method(:branch_not_taken)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = branch_not_taken
      jit.disable!
      assert_equal 3, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_branch_taken
      skip "Please implement branchnil!"

      jit.compile method(:branch_taken)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = branch_taken
      jit.disable!
      assert_nil v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
