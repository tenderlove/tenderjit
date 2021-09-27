# frozen_string_literal: true

require "helper"

class TenderJIT
  class InternTest < JITTest
    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,11)> (catch: FALSE)
    #     0000 putstring                              "c64"                     (   1)[Li]
    #     0002 intern
    #     0003 leave
    #
    def new_symbol
      :"#{'c64'}"
    end

    # Disassembly of the inner code (as of v3.0.2):
    #
    #     == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,48)> (catch: FALSE)
    #     0000 putstring                              "c64"                     (   1)[Li]
    #     0002 intern
    #     0003 opt_send_without_block                 <calldata!mid:object_id, argc:0, ARGS_SIMPLE>
    #     0005 putstring                              "c64"
    #     0007 intern
    #     0008 opt_send_without_block                 <calldata!mid:object_id, argc:0, ARGS_SIMPLE>
    #     0010 newarray                               2
    #     0012 leave
    #
    def existing_symbol
      [:"#{'c64'}".object_id, :"#{'c64'}".object_id]
    end

    def test_new_symbol
      skip "Please implement intern!"

      jit.compile method(:new_symbol)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      v = new_symbol
      jit.disable!
      assert_equal :c64, v

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_existing_symbol
      skip "Please implement intern!"

      jit.compile method(:existing_symbol)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods
      assert_equal 0, jit.exits

      jit.enable!
      id1, id2 = existing_symbol
      jit.disable!
      assert_equal id1, id2

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
