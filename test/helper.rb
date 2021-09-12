ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tenderjit"
require "rbconfig"
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
    end

    def teardown
      super
      self.class.instance_methods(false).each do |m|
        next if m.to_s =~ /^test_/

        meth = method m
        TenderJIT.uncompile(meth) if TenderJIT.compiled?(meth)
      end
    end
  end
end
