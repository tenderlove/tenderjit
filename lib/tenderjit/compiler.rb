require "jit_buffer"
require "tenderjit/fiddle_hacks"
require "tenderjit/compiler/context"
require "tenderjit/ir"
require "tenderjit/yarv"

class TenderJIT
  class Compiler
    include RubyVM::RJIT

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

    UINTPTR_MAX = 0xFFFFFFFFFFFFFFFF
    RBIMPL_VALUE_FULL = UINTPTR_MAX

    def self.vm_block_handler_type
      ir = IR.new
      block_handler = ir.loadp(0)
      # iseq
      unmask = ir.and(block_handler, ir.uimm(0x3))
      _next = ir.label :_next
      ir.jne(unmask, ir.uimm(0x1), _next)
      ir.ret 0 # block_handler_type_iseq

      # ifunc
      ir.put_label _next
      _next = ir.label :_next
      ir.jne(unmask, ir.uimm(0x3), _next)
      ir.ret 1 # block_handler_type_ifunc

      # static symbol
      ir.put_label _next
      mask = (~(RBIMPL_VALUE_FULL << C::RUBY_SPECIAL_SHIFT)) & UINTPTR_MAX
      masked = ir.and block_handler, ir.loadi(ir.uimm(mask))
      _next = ir.label :_next
      ir.jne(masked, ir.loadi(C::RUBY_SYMBOL_FLAG), _next)
      ir.ret 2 # block_handler_type_symbol (static symbol)

      # dynamic symbol
      ir.put_label _next
      _next = ir.label :_next
      ir.jz block_handler, _next # Qfalse
      imm = ir.and block_handler, ir.loadi(C::RUBY_IMMEDIATE_MASK)
      ir.jnz imm, _next          # Special const
      flags = ir.load block_handler, C.RBasic.offsetof(:flags)
      t_type = ir.and flags, ir.loadi(C::RUBY_T_MASK)
      ir.jne t_type, ir.loadi(C::RUBY_T_SYMBOL), _next
      ir.ret 2

      # proc.  It must be a proc type
      ir.put_label _next
      ir.ret 3 # block_handler_type_proc

      buff = JITBuffer.new 4096
      asm = ir.assemble
      buff.writeable!
      asm.write_to buff
      buff.executable!
      buff.to_i
    end

    def self.getblockparamproxy
      # takes EP, and idx
      ir = IR.new

      ep = ir.copy ir.loadp(0)
      idx = ir.loadp(1)

      flags = ir.load(ep, (C::VM_ENV_DATA_INDEX_FLAGS * C.VALUE.size))
      modified = ir.and(flags, C::VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM)

      load_bh = ir.label :load_bh
      ir.jnz(modified, load_bh)

      # VALUE block_handler = VM_ENV_BLOCK_HANDLER(ep);
      block_handler = ir.load(ep, C::VM_ENV_DATA_INDEX_SPECVAL * C.VALUE.size)

      get_handler = ir.label :get_handler
      ir.jnz block_handler, get_handler

      # No block provided
      nil_handler = ir.loadi(Fiddle::Qnil)
      offset = ir.mul(idx, ir.loadi(C.VALUE.size))
      ir.store nil_handler, ir.add(ep, offset), 0
      ir.store ir.or(flags, C::VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM),
               ep,
               (C::VM_ENV_DATA_INDEX_FLAGS * C.VALUE.size)

      ir.ret nil_handler

      ir.put_label get_handler
      block_handler_type = ir.copy ir.call(ir.loadi(Compiler.vm_block_handler_type), [block_handler])
      _next = ir.label :_next
      # block_handler_type_iseq == 0
      # block_handler_type_ifunc == 1
      ir.jgt(block_handler_type, ir.loadi(1), _next)
      ir.ret ir.loadi C.rb_block_param_proxy

      ir.put_label _next
      _next = ir.label :_next
      # block_handler_type_symbol == 2
      ir.jne(block_handler_type, ir.loadi(2), _next)

      bh_sym = ir.call(ir.loadi(C.rb_sym_to_proc), [block_handler])
      offset = ir.mul(idx, ir.loadi(C.VALUE.size))
      ir.store bh_sym, ir.add(ep, offset), 0
      ir.store ir.or(flags, C::VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM),
               ep,
               (C::VM_ENV_DATA_INDEX_FLAGS * C.VALUE.size)
      ir.jmp load_bh
      ir.brk
      ir.nop

      ir.put_label _next
      ir.jne(block_handler_type, ir.loadi(3), _next) # type_proc
      offset = ir.mul(idx, ir.loadi(C.VALUE.size))
      ir.store block_handler, ir.add(ep, offset), 0
      ir.store ir.or(flags, C::VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM),
               ep,
               (C::VM_ENV_DATA_INDEX_FLAGS * C.VALUE.size)
      ir.jmp load_bh

      ir.brk

      ir.put_label _next

      #ir.jmp modify_block_param

      #use_proxy = ir.label :use_proxy
      #ir.jle block_handler_type, ir.loadi(1), use_proxy

      #block_handler_type_proc = ir.label :block_handler_type_proc
      #ir.je block_handler_type, ir.loadi(3), block_handler_type_proc
      #ir.nop
      #ir.nop
      #ir.nop
      #ir.brk

      #ir.put_label block_handler_type_proc

      #ir.brk
      #ir.nop

      #ir.put_label modify_block_param

      #ir.put_label use_proxy
      #proxy = ir.loadi C.rb_block_param_proxy
      ir.put_label load_bh
      offset = ir.mul(idx, ir.loadi(C.VALUE.size))
      ir.ret ir.load(ep, offset)

      buff = JITBuffer.new 4096
      asm = ir.assemble
      buff.writeable!
      asm.write_to buff
      buff.executable!
      buff.to_i
    end


    class PatchCtx < Util::ClassGen.pos(:stack, :buffer_offset, :reg, :ci)
      def argc
        C.vm_ci_argc(ci)
      end

      def mid
        C.vm_ci_mid(ci)
      end
    end

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
        if insn.op == :send
          raise
        else
          send insn.op, context, ir, insn
        end
      end
    end

    def phi context, ir, insn
    end

    def pop context, ir, insn
      context.pop
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

    def getblockparamproxy ctx, ir, insn
      idx, level = insn.opnds

      ep = ir.load(ctx.cfp, ir.uimm(C.rb_control_frame_t.offsetof(:ep)))

      level.times { |i|
        raise
        tmp = ir.load(ep, C::VM_ENV_DATA_INDEX_SPECVAL)
        ep = ir.and(tmp, ~0x03)
      }

      proxy = ir.copy ir.call(ir.loadi(Compiler.getblockparamproxy), [ep, ir.loadi(idx)])

      ctx.push :blockparam, proxy
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
      #mid   = C.vm_ci_mid(cd.ci)
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
        @patches[patch_id] = PatchCtx.new(patch_ctx, loc, func.copy, cd.ci)
      }
      func = ir.loadi ir.uimm(trampoline(argc, patch_id), 64)
      @patch_id += 1

      ctx.push :unknown, ir.copy(ir.call(func, params))
    end

    def splatarray ctx, ir, insn
      l_type = ctx.peek(0)

      return if l_type.array? && insn.opnds.first == 0

      # load the stack pointer
      sp = ir.load(ctx.cfp, C.rb_control_frame_t.offsetof(:sp))

      # Flush the stack
      ctx.each_with_index do |item, index|
        depth = index * Fiddle::SIZEOF_VOIDP
        ir.store(item.reg, sp, ir.uimm(depth))
      end

      # Splatting an array can raise an exception, so we need to flush
      # the PC and the stack
      ir.store(ir.loadi(insn.pc), ctx.cfp, C.rb_control_frame_t.offsetof(:pc))

      # `rb_check_to_array` can raise an exception, so we need to flush
      # the stack
      func = ir.loadi C.rb_vm_splat_array
      res = ir.copy ir.call(func, [ir.loadi(insn.opnds.first), l_type.reg])

      ctx.pop
      ctx.push Hacks.basic_type([]), res
    end

    def newarray ctx, ir, insn
      ary_size = insn.opnds.first

      if ary_size == 0
        func = ir.loadi Hacks::FunctionPointers.rb_ary_new
        res = ir.call func, []
        ctx.push Hacks.basic_type([]), ir.copy(res)
      else
        stack = ary_size.times.map { |i| ctx.peek(i).reg }

        # make sure it's divisible by 2
        stack.unshift IR::NONE if ary_size % 2 > 0

        stack.each_slice(2) { |a, b| ir.push(b, a) }

        argv = ir.copy(ir.loadsp)
        argc = ir.loadi(ary_size)
        func = ir.loadi C.rb_ec_ary_new_from_values
        ary = ir.call(func, [ctx.ec, argc, argv])
        ((ary_size + 1) / 2).times { ir.pop }
        ctx.push Hacks.basic_type([]), ir.copy(ary)
      end
    end

    def opt_getconstant_path ctx, ir, insn
      ic = insn.opnds.first

      exit_label = ir.label(:exit)
      ic = ir.loadi ic.to_i
      ep = ir.load(ctx.cfp, ir.uimm(C.rb_control_frame_t.offsetof(:ep)))
      func = ir.loadi C.rb_vm_ic_hit_p

      ir.tbz ir.call(func, [ic, ep]), 0, exit_label
      generate_exit ctx, ir, insn.pc, exit_label

      ice = ir.load ic, C.IC.offsetof(:entry)
      const_value = ir.load ice, C.iseq_inline_constant_cache_entry.offsetof(:value)
      ctx.push :unknown, const_value
    end

    def opt_not ctx, ir, insn
      opt_send_without_block ctx, ir, insn
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

    EMPTY = [].freeze

    class FakeFrame
      attr_reader :self

      def initialize comptime_self
        @self = Fiddle.dlwrap(comptime_self)
      end
    end

    def compile_frame ec, cfp, comptime_recv, params, patch_id
      patch_ctx = @patches.fetch(patch_id)

      comptime_recv_class = C.rb_class_of(comptime_recv)
      cme = C.rb_callable_method_entry(comptime_recv_class, patch_ctx.mid)

      addr = gen_frame_push ec, cfp, comptime_recv, params, cme, patch_ctx

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

    def gen_frame_push ec, cfp, comptime_recv, comptime_params, cme, patch_ctx
      case cme.def.type
      when C::VM_METHOD_TYPE_ISEQ
        iseq = cme.def.body.iseq.iseqptr
        if iseq.body.jit_func == 0
          comp = TenderJIT::Compiler.new iseq
          iseq.body.jit_func = comp.compile FakeFrame.new(comptime_recv)
        end
        type = C::VM_FRAME_MAGIC_METHOD | C::VM_ENV_FLAG_LOCAL
        call_iseq_frame patch_ctx, type, iseq
      when C::VM_METHOD_TYPE_OPTIMIZED
        gen_optimized_frame ec, cfp, comptime_recv, comptime_params, cme, patch_ctx
      when C::VM_METHOD_TYPE_CFUNC
        push_cfunc_frame ec, cfp, comptime_recv, comptime_params, cme, patch_ctx
      else
        raise "Unhandled frame type #{cme.def.type}"
      end
    end

    def push_cfunc_frame ec, cfp, comptime_recv, comptime_params, cme, ctx
      type = C::VM_FRAME_MAGIC_CFUNC | C::VM_FRAME_FLAG_CFRAME | C::VM_ENV_FLAG_LOCAL
      ir = IR.new

      ec         = ir.copy ir.loadp 0
      caller_cfp = ir.copy ir.loadp 1

      # Move the stack pointer forward enough that the callee won't
      # interfere with the caller's stack, just in case the caller had to write
      # to the stack
      sp = ir.load(caller_cfp, C.rb_control_frame_t.offsetof(:__bp__))
      sp = ir.add(sp, ctx.stack.stack_depth_b)

      # add enough room to the SP to write magic EP values
      sp = ir.add(sp, 3 * C.VALUE.size)
      ir.store(ir.loadi(cme.to_i), sp, -24)
      ir.store(ir.loadi(0), sp, -16) # FIXME: block handler or prev env ptr */;
      ir.store(ir.loadi(type), sp, -8)

      callee_cfp = ir.sub(caller_cfp, C.rb_control_frame_t.size)
      ir.store(sp, callee_cfp, C.rb_control_frame_t.offsetof(:sp))
      ir.store(sp, callee_cfp, C.rb_control_frame_t.offsetof(:__bp__))
      ir.store(
        ir.sub(sp, C.VALUE.size),
        callee_cfp, C.rb_control_frame_t.offsetof(:ep)
      )
      ir.store(ir.loadp(2), callee_cfp, C.rb_control_frame_t.offsetof(:self))
      ir.store(ir.loadi(0), callee_cfp, C.rb_control_frame_t.offsetof(:jit_return))
      ir.store(ir.loadi(0), callee_cfp, C.rb_control_frame_t.offsetof(:block_code))
      ir.store(callee_cfp, ec, C.rb_execution_context_t.offsetof(:cfp))

      ## Push receiver plus parameters on the stack so we can
      ## We're rounding argc up to the nearest multiple of 2, then iterating.
      argc = ctx.argc
      i = (argc + 1) & -2

      (i / 2).times {
        if i > argc
          ir.push(ir.loadp(3 + i - 2))
        else
          ir.push(ir.loadp(3 + i - 1), ir.loadp(3 + i - 2))
        end
        i -= 2
      }
      argv = ir.copy ir.loadsp
      cfunc = cme.def.body.cfunc
      callable = ir.loadi cfunc.invoker.to_i
      recv = ir.copy ir.loadp(2)

      val = ir.call(callable, [recv, ir.loadi(argc), argv, ir.loadi(cfunc.func.to_i)])

      (((argc + 1) & -2) / 2).times { ir.pop }

      ir.store(callee_cfp, ec, C.rb_execution_context_t.offsetof(:cfp))

      ir.ret val

      buff.writeable!
      asm = ir.assemble
      entry = buff.pos + buff.to_i
      asm.write_to buff
      buff.executable!

      entry
    end

    def gen_optimized_frame ec, caller_frame, comptime_recv, comptime_params, cme, ctx
      case cme.def.body.optimized.type
      when C::OPTIMIZED_METHOD_TYPE_CALL
        x = C.rb_control_frame_t.new caller_frame
        block_handler = C.rb_vm_ep_local_ep(x.ep)[C::VM_ENV_DATA_INDEX_SPECVAL]
        p block_handler
        p comptime_recv
        p comptime_params.first
        comptime_recv = comptime_params.first
        comptime_recv_class = C.rb_class_of(comptime_recv)
        p comptime_recv_class
        p Hacks.rb_id2sym(ctx.mid)
        cme = C.rb_callable_method_entry(comptime_recv_class, ctx.mid)
        p cme
        exit!

      when C::OPTIMIZED_METHOD_TYPE_BLOCK_CALL
        x = C.rb_control_frame_t.new caller_frame
        block_handler = C.rb_vm_ep_local_ep(x.ep)[C::VM_ENV_DATA_INDEX_SPECVAL]
        block_handler = block_handler & ~0x3
        captured = C.rb_captured_block.new block_handler
        iseq = captured.code.iseq

        if iseq.body.jit_func == 0
          comp = TenderJIT::Compiler.new iseq
          iseq.body.jit_func = comp.compile FakeFrame.new(captured.self)
        end

        type = C::VM_FRAME_MAGIC_BLOCK
        call_iseq_frame ctx, type, iseq, block: true
      else
        raise "Unknown optimized type #{cme.def.body.optimized.type}"
      end
    end

    def call_iseq_frame ctx, type, iseq, block: false
      ir = IR.new
      ec = ir.loadp 0
      caller_cfp = ir.loadp 1 # load the caller's frame

      recv = if block
               ep = ir.load(caller_cfp, ir.uimm(C.rb_control_frame_t.offsetof(:ep)))
               specval = ir.load(ep, C::VM_ENV_DATA_INDEX_SPECVAL * C.VALUE.size)
               block = ir.and(specval, ~0x3)
               ir.load(block, C.rb_captured_block.offsetof(:self))
             else
               ir.loadp 2
             end

      local_size = 0 # FIXME: reserve room for locals

      # Move the stack pointer forward enough that the callee won't
      # interfere with the caller's stack, just in case the caller had to write
      # to the stack
      sp = ir.load(caller_cfp, C.rb_control_frame_t.offsetof(:__bp__))
      sp = ir.add(sp, ctx.stack.stack_depth_b)

      offset = (ctx.argc - 1) * C.VALUE.size

      # write out parameters to the stack
      ctx.argc.times do |i|
        ir.store(ir.loadp(i + 3), sp, offset)
        offset -= C.VALUE.size
      end

      # FIXME:
      # /* setup ep with managing data */
      # *sp++ = cref_or_me; /* ep[-2] / Qnil or T_IMEMO(cref) or T_IMEMO(ment) */
      # *sp++ = specval     /* ep[-1] / block handler or prev env ptr */;
      # *sp++ = type;       /* ep[-0] / ENV_FLAGS */

      sp = ir.add(sp, (ctx.argc + local_size + 3) * C.VALUE.size)
      ir.store(ir.loadi(0), sp, -24)
      ir.store(ir.loadi(0), sp, -16) # FIXME: block handler or prev env ptr */;
      ir.store(ir.loadi(type), sp, -8)

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
      ir.store(recv, callee_cfp, C.rb_control_frame_t.offsetof(:self))
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

    def trampoline argc, patch_id
      ir = IR.new

      ir.save_params argc + 2 + 1

      ec = ir.copy ir.loadp 0
      cfp = ir.copy ir.loadp 1
      recv = ir.copy ir.loadp 2

      ary = if argc == 0
              ir.loadi(Fiddle.dlwrap(EMPTY))
            else
              ir.loadi(Fiddle.dlwrap(EMPTY))
              ## Push receiver plus parameters on the stack so we can
              ## We're rounding argc up to the nearest multiple of 2, then iterating.
              i = (argc + 1) & -2

              (i / 2).times {
                if i > argc
                  ir.push(ir.loadp(3 + i - 2))
                else
                  ir.push(ir.loadp(3 + i - 1), ir.loadp(3 + i - 2))
                end
                i -= 2
              }

              func = ir.loadi C.rb_ec_ary_new_from_values
              sp = ir.copy ir.loadsp
              x = ir.copy ir.call(func, [ec, ir.loadi(argc), sp])
              i = (argc + 1) & -2
              (i / 2).times { ir.pop }
              x
            end

      # Push parameters for rb_funcallv on the stack
      ir.push(ir.loadi(Fiddle.dlwrap(patch_id)))
      ir.push(recv, ary)
      ir.push(ir.int2num(ec), ir.int2num(cfp))

      argv = ir.copy(ir.loadsp)
      func = ir.loadi Hacks::FunctionPointers.rb_funcallv
      recv = ir.loadi Fiddle.dlwrap(self)
      callback = ir.loadi Hacks.rb_intern_str("compile_frame")
      res = ir.num2int ir.call(func, [recv, callback, ir.loadi(5), argv])

      ir.pop
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
