ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tenderjit/ir"
require "hatstone"
require "jit_buffer"
require "helper"

class TenderJIT
  class IRTest < Test
    include Fiddle::Types

    MINUS = Class.new(Fiddle::Closure) {
      def call x, y
        x - y
      end
    }.create(INT, [INT, INT])

    FUNC = Class.new(Fiddle::Closure) {
      def call x
        x + 5
      end
    }.create(INT, [INT])

    def test_call_with_two_params
      ir = IR.new

      param1 = ir.loadi(400)
      param2 = ir.loadi(200)
      func = ir.loadi MINUS.to_i
      ir.ret ir.call(func, [param1, param2])

      buf = assemble ir
      func = buf.to_function([], INT)
      assert_equal 200, func.call
    end

    def test_call
      ir = IR.new

      param = ir.loadi(123)
      func = ir.loadi FUNC.to_i
      ir.ret ir.call(func, [param])

      buf = assemble ir
      func = buf.to_function([], INT)
      assert_equal 128, func.call
    end

    def test_jfalse
      ir = IR.new
      is_false = ir.label :is_false
      ir.jfalse ir.loadp(0), is_false
      ir.ret 0
      ir.put_label is_false
      ir.ret 1

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([VOIDP], INT)
      assert_equal 1, func.call(Fiddle.dlwrap(nil))
      assert_equal 1, func.call(Fiddle.dlwrap(false))
      assert_equal 0, func.call(Fiddle.dlwrap(Object.new))
      assert_equal 0, func.call(Fiddle.dlwrap(true))
      assert_equal 0, func.call(Fiddle.dlwrap(2.0))
    end

    def test_jnfalse
      ir = IR.new
      not_false = ir.label :not_false
      ir.jnfalse ir.loadp(0), not_false
      ir.ret 0
      ir.put_label not_false
      ir.ret 1

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([VOIDP], INT)
      assert_equal 0, func.call(Fiddle.dlwrap(nil))
      assert_equal 0, func.call(Fiddle.dlwrap(false))
      assert_equal 1, func.call(Fiddle.dlwrap(Object.new))
      assert_equal 1, func.call(Fiddle.dlwrap(true))
      assert_equal 1, func.call(Fiddle.dlwrap(2.0))
    end

    def xtest_lifetime_holes_use_borrowed_regs
      ir = IR.new
      _else = ir.label :else
      _end = ir.label :end

      a = ir.loadp(0)
      p1 = ir.loadp(1)
      z = ir.loadi(123)             # z = 123
      ir.jle a, p1, _else  # if param(0) > param(1)
      b1 = ir.loadi(5)              #   b.1 = 5
      ir.jmp _end

      ir.put_label _else            # else
      c  = ir.loadi(10)             #   c  = 10
      b2 = ir.add(c, z)             #   b.2 = c + z

      ir.put_label _end             # end
      d = ir.add(a, ir.phi(b1, b2)) # d = param(0) + b
      ir.ret d

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([INT, INT], INT)
      assert_equal 10, func.call(5, 3)
      assert_equal 123 + 10 + 3, func.call(3, 5)

      #puts cfg.dump_usage
    end

    # Test and branch if not zero
    def test_tbnz
      ir = IR.new
      a = ir.loadp(0)

      not_zero = ir.label :not_zero
      ir.tbnz a, 0, not_zero
      ir.ret 0
      ir.put_label not_zero
      ir.ret 1

      cfg = ir.basic_blocks
      assert_equal 3, cfg.to_a.length

      ops = cfg.map { |block| block.each_instruction.to_a.last.op }
      assert_equal [:tbnz, :jmp, :ret], ops

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(1)
      assert_equal 0, func.call(2)
    end

    # Test and branch if zero
    def test_tbz
      ir = IR.new
      a = ir.loadp(0)

      is_zero = ir.label(:is_zero)
      ir.tbz a, 0, is_zero
      ir.ret 0
      ir.put_label is_zero
      ir.ret 1

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 0, func.call(1)
      assert_equal 1, func.call(2)
    end

    def test_csel_lt_0
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)

      ir.cmp a, b
      z = ir.loadi(0)
      t = ir.csel_lt(a, z) # t = a < b ? a : b
      ir.ret t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(1, 2)
      assert_equal 0, func.call(2, 1)
    end

    def test_csel_lt
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)

      ir.cmp a, b
      t = ir.csel_lt(a, b) # t = a < b ? a : b
      ir.ret t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(1, 2)
      assert_equal 1, func.call(2, 1)
    end

    def test_csel_gt
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)

      ir.cmp a, b
      t = ir.csel_gt(a, b) # t = a > b ? a : b
      ir.ret t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 2, func.call(1, 2)
      assert_equal 2, func.call(2, 1)
    end

    def test_jo
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadi(0xFFFF_FFFF_FFFF_FFFF >> 1)

      t = ir.add(a, b) # t = a + b
      overflow = ir.label(:overflow)
      ir.jo overflow
      ir.ret t      # return t
      ir.put_label overflow
      ir.ret 1

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(1)
    end

    def test_sub
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)

      t = ir.sub(a, b) # t = a - b
      ir.ret t      # return t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 3, func.call(4, 1)
    end

    def test_sub_lit
      ir = IR.new
      a = ir.loadp(0)
      t = ir.sub(a, 1) # t = a - b
      ir.ret t      # return t
      buf = assemble ir
      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 3, func.call(4)
    end

    def test_bitwise_lit_r
      ir = IR.new
      a = ir.loadp(0)
      t = ir.and(a, 1) # t = a & b
      ir.ret t      # return t
      buf = assemble ir
      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(3)
    end

    def test_bitwise_lit_l
      ir = IR.new
      a = ir.loadp(0)
      t = ir.and(1, a) # t = a & b
      ir.ret t      # return t
      buf = assemble ir
      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(3)
    end

    def test_bitwise
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)
      t = ir.and(a, b) # t = a & b
      ir.ret t      # return t
      buf = assemble ir
      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(3, 1)
    end

    def test_bitwise_lit_lit
      ir = IR.new
      t = ir.and(ir.loadi(3), 1) # t = a & b
      ir.ret t      # return t
      buf = assemble ir
      func = buf.to_function([], Fiddle::TYPE_INT)
      assert_equal 1, func.call()
    end

    def test_ir
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)

      t = ir.add(b, a) # t = a + b
      ir.ret t      # return t

      ir.assemble
      #buf = assemble ir

      #func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      #assert_equal 3, func.call(1, 2)
    end

    def test_add_int_lhs
      ir = IR.new
      a = ir.loadp(0)

      t = ir.add(2, a) # t = a + b
      ir.ret t      # return t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 3, func.call(1)
    end

    def test_read_field
      ir = IR.new
      a = ir.loadp(0)

      # load the value in Parameter 0 at offset 0
      b = ir.load(a, ir.uimm(0))
      # Return the value
      ir.ret b

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      o = Object.new
      assert_equal ra64(Fiddle.dlwrap(o)), func.call(Fiddle.dlwrap(o))
    end

    def test_write
      ir = IR.new
      b = ir.loadi(16)
      ir.ret b

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([], Fiddle::TYPE_INT)

      assert_equal 16, func.call()
    end

    def test_free_twice
      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadp(1)

      t = ir.add(b, a) # t = a + b
      v = ir.add(t, t)
      ir.ret v      # return t

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 6, func.call(1, 2)
    end

    def test_store
      mem = Fiddle.malloc(64)
      val = 0xFF

      ir = IR.new
      a = ir.loadp(0)
      b = ir.loadi(val)
      c = ir.store(b, a, ir.uimm(0))
      ir.ret a

      buf = assemble ir

      assert_nil c

      # Convert the JIT buffer to a function
      func = buf.to_function([VOIDP], VOID)
      func.call(mem)

      assert_equal val, Fiddle::Pointer.new(mem)[0, Fiddle::SIZEOF_INT].unpack1("L")
    ensure
      Fiddle.free mem
    end

    def test_je
      ir = IR.new
      continue = ir.label :continue
      a = ir.loadp(0)
      ir.je a, ir.uimm(0x1), continue
      ir.ret 0
      ir.put_label continue
      ir.ret 1

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(1)
      assert_equal 0, func.call(2)
    end

    def test_je_reg
      ir = IR.new
      continue = ir.label :continue
      a = ir.loadp(0)
      ir.je a, ir.loadp(1), continue
      ir.ret 0
      ir.put_label continue
      ir.ret 1

      buf = assemble ir

      func = buf.to_function([Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 1, func.call(1, 1)
      assert_equal 0, func.call(1, 2)
    end

    def test_jump_forward
      ir = IR.new
      a = ir.loadp(0)

      foo = ir.label :foo
      ir.jmp foo

      # Write a value to x0 but jump over it, making sure the jmp works
      ir.ret ir.loadi(32)

      ir.put_label(foo)
      ir.ret a

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      assert_equal 3, func.call(3)
    end

    def test_immediate_test
      ir = IR.new
      a = ir.loadp(0)

      b = ir.neg a
      c = ir.and a, b
      foo = ir.label(:foo)
      ir.jle c, ir.uimm(4), foo
      ir.ret ir.uimm(0)
      ir.put_label(foo)
      ir.ret ir.uimm(1)

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      assert_equal 1, func.call(3)
      assert_equal 0, func.call(Fiddle.dlwrap(Object.new))
    end

    def test_shr
      ir = IR.new
      ir.ret ir.shr(ir.loadp(0), 1)

      buf = assemble ir

      # Convert the JIT buffer to a function
      func = buf.to_function([INT], INT)

      assert_equal 1, func.call(3)
      assert_equal 1, func.call(2)
    end

    private

    def assemble ir
      asm = ir.assemble

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
