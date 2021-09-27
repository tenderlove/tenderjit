# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptAsetTest < JITTest
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     0000 putnil                                                           (   1)[Li]
    #     0001 newhash                                0
    #     0003 putobject                              :key
    #     0005 putstring                              "val"
    #     0007 setn                                   3
    #     0009 opt_aset                               <calldata!mid:[]=, argc:2, ARGS_SIMPLE>
    #     0011 pop
    #     0012 leave
    #
    def opt_aset_hash
      {}[:key] = 'val'
    end

    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,15)> (catch: FALSE)
    #     0000 putnil                                                           (   1)[Li]
    #     0001 duparray                               [0]
    #     0003 putobject_INT2FIX_1_
    #     0004 putstring                              "val"
    #     0006 setn                                   3
    #     0008 opt_aset                               <calldata!mid:[]=, argc:2, ARGS_SIMPLE>
    #     0010 pop
    #     0011 leave
    #
    # As of 27/Sep/2021, `newarray` (which creates an empty array) is not implemented,
    # so we need to create a filled array (which uses `duparray`).
    #
    def opt_aset_array
      [0][1] = 'val'
    end

    def test_opt_aset_hash
      # This also requires any hash creation instruction to be implemented.
      #
      skip "Please implement opt_aset for hashes!"

      jit.compile method(:opt_aset_hash)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = opt_aset_hash
      jit.disable!
      assert_equal 'val', v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    # Only (absence of) side-effects can be tested, but it's not typical in this
    # project, so only exit/error-free execution is tested.
    #
    def test_opt_aset_array
      skip "Please implement opt_aset for arrays!"

      jit.compile method(:opt_aset_array)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = opt_aset_array
      jit.disable!
      assert_equal 'val', v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
