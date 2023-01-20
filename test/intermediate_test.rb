ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tenderjit/ir"
require "tenderjit/arm64"
require "tenderjit/arm64/register_allocator"
require "tenderjit/arm64/code_gen"
require "hatstone"
require "jit_buffer"

class TenderJIT
  class Test < Minitest::Test
  end
end

class TenderJIT
  class IRTest < Test
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
      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      asm = cg.assemble ra, ir

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
      # Now disassemble the instructions with Hatstone
      hs = Hatstone.new(Hatstone::ARCH_ARM64, Hatstone::MODE_ARM)

      hs.disasm(buf[0, buf.pos], 0x0).each do |insn|
        puts "%#05x %s %s" % [insn.address, insn.mnemonic, insn.op_str]
      end
    end
  end
end
