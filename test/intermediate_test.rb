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

      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      asm = cg.assemble ra, ir

      buf = JITBuffer.new 4096

      buf.writeable!
      asm.write_to buf
      buf.executable!

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

      ra = ARM64::RegisterAllocator.new
      cg = ARM64::CodeGen.new

      asm = cg.assemble ra, ir

      buf = JITBuffer.new 4096

      buf.writeable!
      asm.write_to buf
      buf.executable!

      disasm buf

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      o = Object.new
      assert_equal ra64(Fiddle.dlwrap(o)), func.call(Fiddle.dlwrap(o))
    end

    private

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
