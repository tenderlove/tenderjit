# frozen_string_literal: true

require "helper"

class TenderJIT
  class ExpandarrayTest < JITTest
    def test_expand_array_generic
      mem = Fiddle.malloc(1024)
      list = [1,2,3,4]
      ir = IR.new
      param = ir.loadi Fiddle.dlwrap(list)
      items = Compiler.expand_array ir, param, 3

      # expanding array to 3 elements should return 3 items
      assert_equal 3, items.length
      mem_loc = ir.loadi(mem.to_i)
      ir.store(items[0], mem_loc, 0)
      ir.store(items[1], mem_loc, 8)
      ir.store(items[2], mem_loc, 16)
      ir.ret 0

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = buf.to_function([], Fiddle::TYPE_INT)
      assert_equal 0, func.call
      ptr = Fiddle::Pointer.new mem

      assert_equal [1, 2, 3], ptr[0, 8 * 3].unpack('QQQ').map { |z| Fiddle.dlunwrap z }
    ensure
      Fiddle.free mem
    end

    def test_expand_array_too_short_generic
      mem = Fiddle.malloc(1024)
      list = [1,2]
      ir = IR.new
      param = ir.loadi Fiddle.dlwrap(list)
      items = Compiler.expand_array ir, param, 3

      # expanding array to 3 elements should return 3 items
      assert_equal 3, items.length
      mem_loc = ir.loadi(mem.to_i)
      ir.store(items[0], mem_loc, 0)
      ir.store(items[1], mem_loc, 8)
      ir.store(items[2], mem_loc, 16)
      ir.ret 0

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = buf.to_function([], Fiddle::TYPE_INT)
      assert_equal 0, func.call
      ptr = Fiddle::Pointer.new mem

      assert_equal [1, 2, nil], ptr[0, 8 * 3].unpack('QQQ').map { |z| Fiddle.dlunwrap z }
    ensure
      Fiddle.free mem
    end

    def test_expand_array_empty_generic
      mem = Fiddle.malloc(1024)
      list = []
      ir = IR.new
      param = ir.loadi Fiddle.dlwrap(list)
      items = Compiler.expand_array ir, param, 3

      # expanding array to 3 elements should return 3 items
      assert_equal 3, items.length
      mem_loc = ir.loadi(mem.to_i)
      ir.store(items[0], mem_loc, 0)
      ir.store(items[1], mem_loc, 8)
      ir.store(items[2], mem_loc, 16)
      ir.ret 0

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = buf.to_function([], Fiddle::TYPE_INT)
      assert_equal 0, func.call
      ptr = Fiddle::Pointer.new mem

      assert_equal [nil, nil, nil], ptr[0, 8 * 3].unpack('QQQ').map { |z| Fiddle.dlunwrap z }
    ensure
      Fiddle.free mem
    end

    def test_expand_array_just_right
      mem = Fiddle.malloc(1024)
      list = [3,2,1]
      ir = IR.new
      param = ir.loadi Fiddle.dlwrap(list)
      items = Compiler.expand_array ir, param, 3

      # expanding array to 3 elements should return 3 items
      assert_equal 3, items.length
      mem_loc = ir.loadi(mem.to_i)
      ir.store(items[0], mem_loc, 0)
      ir.store(items[1], mem_loc, 8)
      ir.store(items[2], mem_loc, 16)
      ir.ret 0

      buf = JITBuffer.new 4096
      asm = ir.assemble
      buf.writeable!
      asm.write_to buf
      buf.executable!

      func = buf.to_function([], Fiddle::TYPE_INT)
      assert_equal 0, func.call
      ptr = Fiddle::Pointer.new mem

      assert_equal [3,2,1], ptr[0, 8 * 3].unpack('QQQ').map { |z| Fiddle.dlunwrap z }
    ensure
      Fiddle.free mem
    end

    def expandarray list
      a, b, c = list
      [a, b, c]
    end

    def test_expandarray_not_embedded_long_enough
      expected = expandarray([1, 2, 3, 4])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray([1, 2, 3, 4])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_embedded_to_extended
      expected = expandarray([1, 2, 3, 4])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      # Heat the JIT with an embedded array
      expandarray([1, 2, 3])

      # Call again with an extended array
      actual = expandarray([1, 2, 3, 4])

      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_extended_to_embedded
      expected = expandarray([1, 2, 3])

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      # Heat the JIT with an extended array
      expandarray([1, 2, 3, 4])

      # Call again with an embedded array
      actual = expandarray([1, 2, 3])

      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_heap_embedded_too_short
      expected = expandarray([1, 2])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray([1, 2])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def expandarray_big x
      a, b, c, d, e = x
      [a, b, c, d, e]
    end

    def test_expandarray_heap_extended_too_short
      expected = expandarray_big([1, 2, 3, 4])

      assert_has_insn method(:expandarray_big), insn: :expandarray

      jit.compile method(:expandarray_big)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray_big([1, 2, 3, 4])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_heap_embedded_long_enough
      expected = expandarray([1, 2, 3])

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray([1, 2, 3])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_special_const
      expected = expandarray(true)

      assert_has_insn method(:expandarray), insn: :expandarray

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      actual = expandarray(true)
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_special_const_then_array
      expected = expandarray([1, 2, 3])

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      # heat jit with special const
      expandarray(true)
      actual = expandarray([1, 2, 3])
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 2, jit.executed_methods
      assert_equal 0, jit.exits
    end

    def test_expandarray_hash
      expected = expandarray({a: 1, b: 2})

      jit.compile method(:expandarray)
      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.executed_methods

      jit.enable!
      # heat jit with special const
      actual = expandarray({a: 1, b: 2})
      jit.disable!
      assert_equal expected, actual

      assert_equal 1, jit.compiled_methods
      assert_equal 1, jit.executed_methods
      assert_equal 0, jit.exits
    end
  end
end
