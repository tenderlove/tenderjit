class TenderJIT
  class DeferredCompiler
    attr_reader :buff

    class PatchCtx < Util::ClassGen.pos(:stack, :buffer_offset, :reg, :ci)
      def argc
        C.vm_ci_argc(ci)
      end

      def mid
        C.vm_ci_mid(ci)
      end

      def splat?
        C.vm_ci_flag(ci) & C::VM_CALL_ARGS_SPLAT > 0
      end
    end

    def initialize buff
      @trampolines = JITBuffer.new 4096
      puts TRAMPOLINES: @trampolines.to_i.to_s(16)
      @patch_id = 0
      @patches = []
      @buff = buff
    end

    def gen_opt_aset ec, cfp, recv, idx, val, patch_id
      ctx = @patches.fetch(patch_id)

      case Hacks.basic_type(recv)
      when :T_HASH
        ir = IR.new
        func_addr = ir.loadi C.rb_hash_aset
        ir.ret ir.call(func_addr, [ir.loadp(2), ir.loadp(3), ir.loadp(4)])

        entry = buff.pos + buff.to_i
        buff.writeable!
        ir.assemble.write_to buff
        buff.executable!

        ir = IR.new
        ir.storei(entry, ctx.reg)
        asm = ir.assemble_patch

        pos = buff.pos
        buff.seek ctx.buffer_offset
        buff.writeable!
        asm.write_to(buff)
        buff.executable!
        buff.seek pos

        entry
      when :T_ARRAY
        ir = IR.new
        func_addr = ir.loadi C.rb_ary_store
        ir.ret ir.call(func_addr, [ir.loadp(2), ir.loadp(3), ir.loadp(4)])

        entry = buff.pos + buff.to_i
        buff.writeable!
        ir.assemble.write_to buff
        buff.executable!

        ir = IR.new
        ir.storei(entry, ctx.reg)
        asm = ir.assemble_patch

        pos = buff.pos
        buff.seek ctx.buffer_offset
        buff.writeable!
        asm.write_to(buff)
        buff.executable!
        buff.seek pos

        entry
      else
        raise
      end
    end

    def opt_aset comp, stack, ir, insn
      cd = insn.opnds.first
      patch_ctx = stack.dup

      func = patched_loadi(ir, ->(patch_id) { method_call_trampline(patch_id, 3, "gen_opt_aset") },
                               ->(loc, opnd) { PatchCtx.new(patch_ctx, loc, func.copy, cd.ci) })

      val = stack.pop.reg
      idx = stack.pop.reg
      recv = stack.pop.reg
      params = [stack.ec, stack.cfp, recv, idx, val]
      stack.push :unknown, ir.copy(ir.call(func, params))
    end

    private

    def method_call_trampline patch_id, argc, callback
      ir = IR.new
      ir.storep(argc + 2 + 1, ir.uimm(patch_id))
      ir.save_params(argc + 2 + 1) # ec and cfp + argc  push 6

      ir.push(ir.loadp(4), ir.loadi(Fiddle.dlwrap(patch_id))) # push 2
      ir.push(ir.loadp(2), ir.loadp(3)) # push 2
      ir.push(ir.int2num(ir.loadp(0)), ir.int2num(ir.loadp(1))) # push 2

      argv = ir.copy(ir.loadsp)
      func = ir.loadi Hacks::FunctionPointers.rb_funcallv

      recv = ir.loadi Fiddle.dlwrap(self)
      callback = ir.loadi Hacks.rb_intern_str(callback)
      # argc + cfp + ec + patch_id
      res = ir.num2int ir.call(func, [recv, callback, ir.loadi(argc + 2 + 1), argv])

      ir.pop # pop 2
      ir.pop # pop 2
      ir.pop # pop 2

      ir.restore_params argc + 1 + 2 # pop 6
      ir.ret ir.call(res, (argc + 2).times.map { |i| ir.loadp(i) })

      asm = ir.assemble
      addr = @trampolines.to_i + @trampolines.pos
      @trampolines.writeable!
      asm.write_to @trampolines
      @trampolines.executable!
      addr
    end

    def patched_loadi ir, before_assembly, at_assembly
      patch_id = @patch_id
      address = before_assembly.call(patch_id)
      func = nil
      ir.patch_location { |loc| @patches[patch_id] = at_assembly.call(loc, func) }
      @patch_id += 1
      func = ir.loadi ir.uimm(address, 64)
      func
    end
  end
end
