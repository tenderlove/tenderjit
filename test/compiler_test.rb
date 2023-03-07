require "helper"

class TenderJIT
  class CompilerTest < Test
    def test_compile_foo
      compiler = Compiler.for_method method(:foo)
      cfg = compiler.yarv.cfg
      cfg.each { |bb|
        p bb.name => bb.df.map(&:name)
      }
      File.binwrite "out.dot", cfg.to_dot
    end

    def test_newarray_pop
      compiler = Compiler.for_method method(:bar)
      cfg = compiler.yarv.cfg
      insn = cfg.each_instruction.find { |insn| insn.op == :newarray }
      assert_equal 1, insn.stack_push
      assert_equal 3, insn.stack_pop
    end

    def test_compile_bar
      compiler = Compiler.for_method method(:bar)
      cfg = compiler.yarv.cfg
      cfg.each { |bb|
        bb.each_instruction do |insn|
          p insn.op => insn.stack_pos
        end
      }
      File.binwrite "out.dot", cfg.to_dot
    end

    def bar x
      [x, x, x < 10 ? 123 : 456]
    end

    def foo z
      x = 1234
      while x > 123
        x -= z
      end
      x + 123
    end
  end
end
