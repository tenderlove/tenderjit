require "jit_buffer"
require "tenderjit/fiddle_hacks"
require "tenderjit/compiler/context"
require "tenderjit/ir"
require "tenderjit/yarv"

class TenderJIT
  class Compiler
    def self.for_method method
      rb_iseq = RubyVM::InstructionSequence.of(method)
      return unless rb_iseq # it's a C func
      new method_to_iseq_t(rb_iseq)
    end

    def self.uncompile method
      rb_iseq = RubyVM::InstructionSequence.of(method)
      return unless rb_iseq # it's a C func

      iseq = method_to_iseq_t(rb_iseq)
      cov_ptr = iseq.body.variable.coverage.to_i

      unless cov_ptr == 0 || cov_ptr == Fiddle::Qnil
        iseq.body.variable.coverage = 0
      end

      iseq.body.jit_func = 0
    end

    def self.method_to_iseq_t method
      addr = Fiddle.dlwrap(method)
      offset = Hacks::STRUCTS["RTypedData"]["data"][0]
      addr = Fiddle.read_ptr addr, offset
      C.rb_iseq_t.new addr
    end

    def self.new iseq
      cov_ptr = iseq.body.variable.coverage.to_i

      ary = nil
      if cov_ptr == 0 || cov_ptr == Fiddle::Qnil
        ary = []
        ary_addr = Fiddle.dlwrap(ary)
        iseq.body.variable.coverage = ary_addr
        Hacks.rb_gc_writebarrier(iseq, ary_addr)
      else
        ary = Fiddle.dlunwrap(iseq.body.variable.coverage)
      end

      # COVERAGE_INDEX_LINES is 0
      # COVERAGE_INDEX_BRANCHES is 1
      # 2 is unused so we'll use it. :D

      # Cache the iseq compiler for this iseq inside the code coverage array.
      if ary[2]
        puts "this shouldn't happen, I don't think"
      else
       iseq_compiler = super
        ary[2] = iseq_compiler
      end

      ary[2]
    end

    PatchCtx = Util::ClassGen.pos(:stack, :buffer_offset, :reg)

    attr_reader :iseq, :buff

    def initialize iseq
      @iseq = iseq
      @trampolines = JITBuffer.new 4096
      @buff = JITBuffer.new 4096
      @yarv_labels = {}
      @trampoline_index = []
      @patches = []
      @patch_id = 0
    end

    def yarv
      yarv_ir(@iseq)
    end

    def compile comptime_frame
      # method name
      label = iseq.body.location.label
      puts "COMPILING #{label}" if $DEBUG

      STATS.compiled_methods += 1

      ir = IR.new

      ec  = ir.loadp(0)
      cfp = ir.loadp(1)

      ec = ir.copy ec

      ctx = Context.new(buff, ec, cfp, comptime_frame)

      # Increment executed method count
      stats_location = ir.loadi(STATS.to_i)
      stat = ir.load(stats_location, ir.uimm(Stats.offsetof("executed_methods")))
      inc = ir.add(stat, ir.uimm(0x1))
      ir.store(inc, stats_location, ir.uimm(Stats.offsetof("executed_methods")))

      cfg = yarv.basic_blocks

      translate_cfg cfg, ir, ctx
      asm = ir.assemble

      buff.writeable!
      asm.write_to buff

      disasm buff if $DEBUG

      buff.executable!

      puts "DONE COMPILING #{label}" if $DEBUG
      buff.to_i
    end

    private

    ##
    # Translate a CFG to IR
    def translate_cfg bbs, ir, context
      seen = {}
      worklist = [[bbs.first, context]]
      while work = worklist.pop
        yarv_block, context = *work
        # If we've seen the block before, it must be a joint point
        if seen[yarv_block]
          prev_context, insns = seen[yarv_block]

          # Add a phi function for stack items that differ
          prev_context.zip(context).reject { |left, right|
            left.reg == right.reg
          }.each { |existing, new|
            ir.insert_at(insns._next) { ir.phi existing.reg, new.reg }
          }

          # Make phi functions for locals
          yarv_block.phis.map(&:out).map(&:name).each { |name|
            existing = prev_context.get_local name
            new = context.get_local name
            ir.insert_at(insns._next) { ir.phi existing.reg, new.reg }
          }

          phis = []
          ## Walk past the phi nodes
          iter = insns._next._next
          while iter.phi?
            phis << iter
            iter = iter._next
          end

          old_vars = phis.each_with_object({}) { |phi, out|
            out[phi.arg1] = phi.out
            out[phi.arg2] = phi.out
          }

          needs_fixing = []

          while iter != ir.current_instruction
            if old_vars.key?(iter.arg1) || old_vars.key?(iter.arg2)
              needs_fixing << iter
            end
            iter = iter._next
          end

          # Replace instructions so they point at the phi output instead of
          # the original input
          needs_fixing.each do |insn|
            arg1 = old_vars[insn.arg1] || insn.arg1
            arg2 = old_vars[insn.arg2] || insn.arg2
            insn.replace arg1, arg2
          end
        else
          seen[yarv_block] = [context.dup, ir.current_instruction]
          translate_block yarv_block, ir, context
          if yarv_block.out1
            worklist.unshift [yarv_block.out1, context]
          end
          if yarv_block.out2
            # If we have a fork, we need to dup the stack
            worklist.unshift [yarv_block.out2, context.dup]
          end
        end
      end
    end

    def translate_block block, ir, context
      block.each_instruction do |insn|
        puts insn.op if $DEBUG
        send insn.op, context, ir, insn
      end
    end

    def phi context, ir, insn
    end

    def yarv_ir iseq
      jit_pc = 0

      # Size of the ISEQ buffer
      iseq_size = iseq.body.iseq_size

      # ISEQ buffer
      iseq_buf = iseq.body.iseq_encoded

      local_table_head = Fiddle.read_ptr iseq.body[:local_table].to_i, 0
      list = if local_table_head == 0
        []
      else
        Fiddle::CArray.unpack Fiddle::Pointer.new(local_table_head),
          iseq.body.local_table_size,
          Fiddle::TYPE_UINTPTR_T
      end

      locals = list.map { Hacks.rb_id2sym _1 }

      yarv = YARV.new iseq, locals

      while jit_pc < iseq_size
        addr = iseq_buf.to_i + (jit_pc * Fiddle::SIZEOF_VOIDP)
        insn = INSNS.fetch C.rb_vm_insn_decode(Fiddle.read_ptr(addr, 0))
        yarv.handle addr, insn

        jit_pc += insn.len
      end

      yarv.peephole_optimize!

      yarv
    end

    def branchunless ctx, ir, insn
      label = yarv_label(ir, insn.opnds.first)

      temp = ctx.pop
      ir.jfalse temp.reg, label
    end

    def dup ctx, ir, insn
      top = ctx.top
      ctx.push top.type, top.reg
    end

    def jump ctx, ir, insn
      label = yarv_label(ir, insn.opnds.first)
      ir.jmp label
    end

    def putself ctx, ir, insn
      unless ctx.recv
        self_reg = ir.load(ctx.cfp, ir.uimm(C.rb_control_frame_t.offsetof(:self)))
        ctx.recv = self_reg
      end
      ctx.push Hacks.basic_type(Fiddle.dlunwrap(ctx.comptime_cfp.self)), ctx.recv
    end

    def put_label ctx, ir, insn
      ir.put_label yarv_label(ir, insn.opnds.first)
    end

    def putobject ctx, ir, insn
      obj = insn.opnds.first
      out = ir.loadi(Fiddle.dlwrap(obj))
      ctx.push Hacks.basic_type(obj), out
    end

    def opt_send_without_block ctx, ir, insn
      cd = insn.opnds.first
      mid   = C.vm_ci_mid(cd.ci)
      argc  = C.vm_ci_argc(cd.ci)
      #flags = C.vm_ci_flag(cd.ci)

      params = [ ctx.ec, ctx.cfp ]
      callee_params = argc.times.map { ctx.pop.reg }
      params << ctx.pop.reg # recv
      params += callee_params

      patch_id = @patch_id
      patch_ctx = ctx.dup

      func = nil
      ir.patch_location { |loc|
        @patches[patch_id] = PatchCtx.new(patch_ctx, loc, func.copy)
      }
      func = ir.loadi ir.uimm(trampoline(mid, argc, patch_id), 64)
      @patch_id += 1

      ctx.push :unknown, ir.copy(ir.call(func, params))
    end

    def opt_mod ctx, ir, insn
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      right = r_type.reg

      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = l_type.reg

      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      unless l_type.fixnum? && r_type.fixnum?
        # Generate an exit
        generate_exit ctx, ir, insn.pc, exit_label
      end

      out = ir.mod left, right

      ctx.pop
      ctx.pop
      ctx.push(Hacks.basic_type(123), out)
    end

    def opt_eq ctx, ir, insn
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      right = r_type.reg

      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = l_type.reg

      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      unless l_type.fixnum? && r_type.fixnum?
        # Generate an exit
        generate_exit ctx, ir, insn.pc, exit_label
      end

      ir.cmp left, right
      out = ir.csel_eq ir.loadi(Fiddle::Qtrue), ir.loadi(Fiddle::Qfalse)

      ctx.pop
      ctx.pop
      ctx.push(:BOOLEAN, out)
    end

    def opt_lt ctx, ir, insn
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      right = r_type.reg

      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = l_type.reg

      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      unless l_type.fixnum? && r_type.fixnum?
        # Generate an exit
        generate_exit ctx, ir, insn.pc, exit_label
      end

      ir.cmp left, right
      out = ir.csel_lt ir.loadi(Fiddle::Qtrue), ir.loadi(Fiddle::Qfalse)

      ctx.pop
      ctx.pop
      ctx.push(:BOOLEAN, out)
    end

    def opt_gt ctx, ir, insn
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      unless l_type.fixnum? && r_type.fixnum?
        # Generate an exit
        generate_exit ctx, ir, insn.pc, exit_label
      end

      right = r_type.reg

      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = l_type.reg

      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      ir.cmp left, right
      out = ir.csel_gt ir.loadi(Fiddle::Qtrue), ir.loadi(Fiddle::Qfalse)

      ctx.pop
      ctx.pop
      ctx.push(:BOOLEAN, out)
    end

    def opt_plus ctx, ir, insn
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      right = r_type.reg

      # Only test the type at runtime if we don't know for sure
      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = l_type.reg

      # Only test the type at runtime if we don't know for sure
      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      # subtract the mask from one side
      right = ir.sub right, ir.uimm(0x1)

      # Add them
      out = ir.add(left, right)
      ir.jo exit_label

      # Generate an exit in case of overflow or not fixnums
      generate_exit ctx, ir, insn.pc, exit_label

      ctx.pop
      ctx.pop
      ctx.push(Hacks.basic_type(123), out)
    end

    def opt_minus ctx, ir, insn
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      right = r_type.reg

      # Only test the type at runtime if we don't know for sure
      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = l_type.reg

      # Only test the type at runtime if we don't know for sure
      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      # Subtract them
      out = ir.sub(left, right)
      ir.jo exit_label

      # Add the tag again
      out = ir.add out, ir.uimm(0x1)

      # Generate an exit in case of overflow or not fixnums
      generate_exit ctx, ir, insn.pc, exit_label

      ctx.pop
      ctx.pop
      ctx.push(Hacks.basic_type(123), out)
    end

    def setlocal ctx, ir, insn
      local = insn.opnds
      item = ctx.pop
      ctx.set_local local.name, item.type, item.reg
    end

    def getlocal ctx, ir, insn
      local = insn.opnds
      unless ctx.have_local?(local.name)
        # If the local hasn't been loaded yet, load it
        ep = ir.load(ctx.cfp, ir.uimm(C.rb_control_frame_t.offsetof(:ep)))
        index, _ = local.ops
        var = ir.load(ep, ir.imm(-index * Fiddle::SIZEOF_VOIDP))
        ctx.set_local local.name, :unknown, var
      end
      local_item = ctx.get_local local.name
      ctx.push local_item.type, local_item.reg
    end

    def leave ctx, ir, opnds
      item = ctx.pop

      prev_frame = ir.add ctx.cfp, ir.uimm(C.rb_control_frame_t.size)
      ir.store(prev_frame, ctx.ec, ir.uimm(C.rb_execution_context_t.offsetof(:cfp)))

      ir.ret item.reg
    end

    def disasm buf
      TenderJIT.disasm buf
    end

    def generate_exit ctx, ir, vm_pc, exit_label
      pass = ir.label :pass
      ir.jmp pass

      ir.put_label exit_label

      # load the stack pointer
      sp = ir.load(ctx.cfp, C.rb_control_frame_t.offsetof(:sp))

      # Flush the stack
      ctx.each_with_index do |item, index|
        depth = index * Fiddle::SIZEOF_VOIDP
        ir.store(item.reg, sp, ir.uimm(depth))
      end

      # Store the new SP on the frame
      sp = ir.add(sp, ctx.stack_depth_b)
      ir.store(sp, ctx.cfp, C.rb_control_frame_t.offsetof(:sp))

      # Update the PC
      ir.store(ir.loadi(vm_pc), ctx.cfp, C.rb_control_frame_t.offsetof(:pc))

      stats_location = ir.loadi(STATS.to_i)
      stat = ir.load(stats_location, Stats.offsetof("exits"))
      inc = ir.add(stat, 0x1)
      ir.store(inc, stats_location, Stats.offsetof("exits"))

      ir.ret Fiddle::Qundef
      ir.put_label pass
    end

    def guard_fixnum ir, reg, exit_label
      ir.tbz reg, 0, exit_label # exit if bottom bit is 0
    end

    ##
    # Look up a yarv label and translate it to an IR label
    def yarv_label ir, label
      @yarv_labels[label.name] ||= ir.label("YARV: #{label.name}")
    end

    class FakeFrame; end

    def compile_frame comptime_recv, mid, argc, patch_id
      patch_ctx = @patches.fetch(patch_id)

      comptime_recv_class = C.rb_class_of(comptime_recv)
      cme = C.rb_callable_method_entry(comptime_recv_class, mid)

      addr = gen_frame_push cme, patch_ctx, argc

      ir = IR.new
      ir.storei(addr, patch_ctx.reg)
      asm = ir.assemble_patch

      pos = buff.pos
      buff.seek patch_ctx.buffer_offset
      buff.writeable!
      asm.write_to(buff)
      buff.executable!
      buff.seek pos

      # need:
      #   * receiver
      #   * method id
      #   * number of params
      # Generated frame's calling convention
      #   push_frame(ec, cfp, recv, param1, param2, ...)
      addr
    end

    def gen_frame_push cme, patch_ctx, argc
      case cme.def.type
      when C::VM_METHOD_TYPE_ISEQ
        iseq = cme.def.body.iseq.iseqptr
        if iseq.body.jit_func == 0
          comp = TenderJIT::Compiler.new iseq
          iseq.body.jit_func = comp.compile FakeFrame.new
        end
        call_iseq_frame patch_ctx.stack, iseq, argc
      else
        raise
      end
    end

    def call_iseq_frame ctx, iseq, argc
      ir = IR.new
      ec = ir.loadp 0
      caller_cfp = ir.loadp 1 # load the caller's frame

      local_size = 0 # FIXME: reserve room for locals

      # Move the stack pointer forward enough that the callee won't
      # interfere with the caller's stack, just in case the caller had to write
      # to the stack
      sp = ir.load(caller_cfp, C.rb_control_frame_t.offsetof(:__bp__))
      sp = ir.add(sp, ctx.stack_depth_b)

      offset = (argc - 1) * C.VALUE.size

      argc.times do |i|
        ir.store(ir.loadp(i + 3), sp, offset)
        offset -= C.VALUE.size
      end

      # FIXME:
      # /* setup ep with managing data */
      # *sp++ = cref_or_me; /* ep[-2] / Qnil or T_IMEMO(cref) or T_IMEMO(ment) */
      # *sp++ = specval     /* ep[-1] / block handler or prev env ptr */;
      # *sp++ = type;       /* ep[-0] / ENV_FLAGS */

      sp = ir.add(sp, (argc + local_size + 3) * C.VALUE.size)

      pc = 123

      callee_cfp = ir.sub(caller_cfp, C.rb_control_frame_t.size)
      ir.store(ir.loadi(pc), callee_cfp, C.rb_control_frame_t.offsetof(:pc))
      ir.store(sp, callee_cfp, C.rb_control_frame_t.offsetof(:sp))
      ir.store(sp, callee_cfp, C.rb_control_frame_t.offsetof(:__bp__))
      ir.store(
        ir.sub(sp, C.VALUE.size),
        callee_cfp, C.rb_control_frame_t.offsetof(:ep)
      )
      ir.store(ir.loadi(iseq.to_i), callee_cfp, C.rb_control_frame_t.offsetof(:iseq))
      ir.store(ir.loadp(2), callee_cfp, C.rb_control_frame_t.offsetof(:self))
      ir.store(ir.loadi(0), callee_cfp, C.rb_control_frame_t.offsetof(:jit_return))
      ir.store(ir.loadi(0), callee_cfp, C.rb_control_frame_t.offsetof(:block_code))
      ir.store(callee_cfp, ec, C.rb_execution_context_t.offsetof(:cfp))

      callee_iseq = iseq.body.jit_func
      iseq_location = ir.loadi(callee_iseq)
      ir.ret ir.call(iseq_location, [ec, callee_cfp])

      asm = ir.assemble
      buff.writeable!
      entry = buff.pos + buff.to_i
      asm.write_to buff
      buff.executable!

      entry
    end

    def trampoline mid, argc, patch_id
      ir = IR.new

      # push ec and cfp on stack

      ir.save_params argc + 2 + 1

      # Push parameters for rb_funcallv on the stack
      ir.push(ir.loadi(Fiddle.dlwrap(argc)), ir.loadi(Fiddle.dlwrap(patch_id)))
      ir.push(ir.loadp(2), ir.loadi(Fiddle.dlwrap(mid)))
      argv = ir.copy(ir.loadsp)
      func = ir.loadi Fiddle::Handle::DEFAULT["rb_funcallv"]
      recv = ir.loadi Fiddle.dlwrap(self)
      callback = ir.loadi Hacks.rb_intern_str("compile_frame")

      res = ir.call func, [recv, callback, ir.loadi(4), argv]
      res = ir.shr res, 1
      ir.pop
      ir.pop

      ir.restore_params argc + 2 + 1

      m = ir.call(res, (argc + 2 + 1).times.map { |i| ir.loadp(i) })
      ir.ret m

      asm = ir.assemble
      addr = @trampolines.to_i + @trampolines.pos
      @trampolines.writeable!
      asm.write_to @trampolines
      @trampolines.executable!
      addr
    end
  end
end
