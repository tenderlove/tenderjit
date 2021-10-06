# frozen_string_literal: true

require "helper"

class TenderJIT
  class SetnTest < JITTest
    # Disassembly of the inner code (as of v3.1.0):
    #
    #     0000 putnil                                                           (   9)[LiCa]
    #     0001 putobject                              :key
    #     0003 putstring                              "something"
    #     0005 newhash                                2
    #     0007 putobject                              :key
    #     0009 putstring                              "val"
    #     0011 setn                                   3
    #     0013 opt_aset                               <calldata!mid:[]=, argc:2, ARGS_SIMPLE>[CcCr]
    #     0015 pop
    #     0016 leave                                                            (  10)[Re]
    #
    def opt_setn
      {key: 'something'}[:key] = 'val'
    end

    def test_setn
      jit.compile method(:opt_setn)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = opt_setn
      jit.disable!
      assert_equal 'val', v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
