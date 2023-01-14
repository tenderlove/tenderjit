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

      t = ir.add(a, b) # t = a + b
      ir.return t      # return t

      ra = ARM64::RegisterAllocator.new(
        ARM64::PARAM_REGS,
        ARM64::FREE_REGS,
      )

      cg = ARM64::CodeGen.new
      asm = cg.assemble ra, ir

      buf = JITBuffer.new 4096

      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 3, func.call(1, 2)
    end
  end
end
