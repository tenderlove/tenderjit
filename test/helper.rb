ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "make_warnings_errors"
require "tenderjit"
require "rbconfig"
require "registers_saving_buffer"
require "fisk"
require "fisk/helpers"

class TenderJIT
  class Test < Minitest::Test
    include Fiddle

    module Hacks
      fisk = Fisk.new

      jitbuf = Fisk::Helpers.jitbuffer 4096

      fisk.asm(jitbuf) do
        push rbp
        mov rbp, rsp
        int lit(3)
        pop rbp
        ret
      end

      define_singleton_method :halt!, &jitbuf.to_function([], Fiddle::TYPE_VOID)
    end
  end

  class JITTest < Test
    attr_reader :jit

    def setup
      @jit = TenderJIT.new
      super
    end

    def teardown
      @jit.uncompile_iseqs
    end


    def assert_change thing, by: 1
      initial = thing.call
      yield
      assert_equal initial + by, thing.call
    end

    def assert_has_insn method, insn:
      iseq = RubyVM::InstructionSequence.of(method)
      assert_includes iseq.to_a.flatten, insn
    end

    def assert_jit method, compiled:, executed:, exits:
      jit = TenderJIT.new
      jit.compile method

      before_executed = jit.executed_methods

      jit.enable!
      v = method.call
      jit.disable!

      assert_equal compiled, jit.compiled_methods, "compiled"
      assert_equal executed, jit.executed_methods - before_executed, "executed"
      assert_equal exits, jit.exits, "exits"
      v
    ensure
      jit.uncompile_iseqs
    end
  end
end
