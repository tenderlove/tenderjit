ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tenderjit/ir"
require "hatstone"
require "jit_buffer"
require "helper"

class TenderJIT
  class IRTest < Test
    include Fiddle::Types

    def test_ir
      ir = IR.new
      a = ir.param(0)
      b = ir.param(1)

      t = ir.add(b, a) # t = a + b
      ir.return t      # return t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 3, func.call(1, 2)
    end

    def test_add_int_lhs
      ir = IR.new
      a = ir.param(0)

      t = ir.add(2, a) # t = a + b
      ir.return t      # return t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 3, func.call(1)
    end

    def test_read_field
      ir = IR.new
      a = ir.param(0)

      # load the value in Parameter 0 at offset 0
      b = ir.load(a, ir.uimm(0))
      # Return the value
      ir.return b

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      o = Object.new
      assert_equal ra64(Fiddle.dlwrap(o)), func.call(Fiddle.dlwrap(o))
    end

    def test_write
      ir = IR.new
      a = ir.param(0)
      b = ir.write(a, ir.uimm(16))
      ir.return b

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([], Fiddle::TYPE_INT)

      assert_equal 16, func.call()
    end

    def test_free_twice
      ir = IR.new
      a = ir.param(0)
      b = ir.param(1)

      t = ir.add(b, a) # t = a + b
      v = ir.add(t, t)
      ir.return v      # return t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 6, func.call(1, 2)
    end

    def test_store
      mem = Fiddle.malloc(64)
      val = 0xFF

      ir = IR.new
      a = ir.param(0)
      b = ir.write(ir.var, ir.uimm(val))
      c = ir.store(b, a, ir.uimm(0))
      ir.return a

      buf = assemble ir

      assert_nil c

      # Convert the JIT buffer to a function
      func = buf.to_function([VOIDP], VOID)
      func.call(mem)

      assert_equal val, Fiddle::Pointer.new(mem)[0, Fiddle::SIZEOF_INT].unpack1("L")
    ensure
      Fiddle.free mem
    end

    def test_jump_forward
      ir = IR.new
      a = ir.param(0)

      ir.jmp ir.label(:foo)

      # Write a value to x0 but jump over it, making sure the jmp works
      ir.return ir.write(a, ir.uimm(32))
      b = ir.load(a, ir.uimm(0))

      ir.put_label(:foo)
      ir.return a

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      assert_equal 3, func.call(3)
    end

    def test_immediate_test
      ir = IR.new
      a = ir.param(0)

      b = ir.neg a
      c = ir.and a, b
      ir.jle c, ir.uimm(4), ir.label(:foo)
      ir.return ir.uimm(0)
      ir.put_label(:foo)
      ir.return ir.uimm(1)

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      assert_equal 1, func.call(3)
      assert_equal 0, func.call(Fiddle.dlwrap(Object.new))
    end

    private

    def assemble ir
      asm = ir.to_binary

      buf = JITBuffer.new 4096

      buf.writeable!
      asm.write_to buf
      buf.executable!

      buf
    end

    def ra64 ptr
      Fiddle::Pointer.new(ptr)[0, Fiddle::SIZEOF_INT].unpack1("L")
    end

    def disasm buf
      TenderJIT.disasm buf
    end
  end
end
