require "helper"

class TenderJIT
  class CompilerTest < Test
    def test_array_empty
      ir = IR.new
      ary = ir.loadp(0)
      idx = ir.loadp(1)
      item = Compiler.rarray_aref ir, ary, idx
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      list = []
      idx = 2
      item = list[idx]

      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
      assert_nil Fiddle.dlunwrap(func.call(Fiddle.dlwrap(list), idx))
    end

    def test_array_aref_neg
      skip "PENDING"
      ir = IR.new
      ary = ir.loadp(0)
      idx = ir.loadp(1)
      item = Compiler.rarray_aref ir, ary, idx
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      list = [1, 2, 5]
      idx = -2
      item = list[idx]

      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
      assert_equal item, Fiddle.dlunwrap(func.call(Fiddle.dlwrap(list), idx))
    end

    def test_array_aref_oob
      ir = IR.new
      ary = ir.loadp(0)
      idx = ir.loadp(1)
      item = Compiler.rarray_aref ir, ary, idx
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
      assert_nil Fiddle.dlunwrap(func.call(Fiddle.dlwrap([1, 2, 5]), 3))
    end

    def test_array_aref_extended
      ir = IR.new
      ary = ir.loadp(0)
      idx = ir.loadp(1)
      item = Compiler.rarray_aref ir, ary, idx
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      ary = []
      20.times { |i| ary << i + 3 }

      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
      assert_equal 5, Fiddle.dlunwrap(func.call(Fiddle.dlwrap(ary), 2))
    end

    def test_array_aref_embedded
      ir = IR.new
      ary = ir.loadp(0)
      idx = ir.loadp(1)
      item = Compiler.rarray_aref ir, ary, idx
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
      assert_equal 5, Fiddle.dlunwrap(func.call(Fiddle.dlwrap([1, 2, 5]), 2))
    end

    def test_array_len_embedded
      ir = IR.new
      ary = ir.loadp(0)
      item = Compiler.rarray_len ir, ary
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      assert_equal 3, func.call(Fiddle.dlwrap([1, 2, 5]))
    end

    def test_array_len_extended
      ir = IR.new
      ary = ir.loadp(0)
      item = Compiler.rarray_len ir, ary
      ir.ret item

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      ary = []
      20.times { |i| ary << i + 3 }
      func = Fiddle::Function.new(buf.to_i, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      assert_equal 20, func.call(Fiddle.dlwrap(ary))
    end

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
