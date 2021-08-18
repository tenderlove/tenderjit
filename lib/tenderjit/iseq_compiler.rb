require "tenderjit/temp_stack"
require "tenderjit/runtime"

class TenderJIT
  class ISEQCompiler
    SCRATCH_REGISTERS = [
      Fisk::Registers::R9,
      Fisk::Registers::R10,
    ]

    attr_reader :blocks

    def initialize jit, addr
      if $DEBUG
        puts "Compiling iseq addr: #{sprintf("%#x", addr)}"
      end

      @jit        = jit
      @temp_stack = TempStack.new
      @iseq       = addr
      @body       = RbISeqT.new(addr).body
      @insns      = Fiddle::CArray.unpack(@body.iseq_encoded,
                                          @body.iseq_size,
                                          Fiddle::TYPE_VOIDP)

      @insn_idx   = nil
      @current_pc = nil
      @fisk       = nil

      @blocks     = []
      @compile_requests = []
      @objects = []
    end

    def stats; @jit.stats; end

    def __
      @fisk
    end

    def recompile!
      @temp_stack = TempStack.new
      @body.jit_func = 0
      @insn_idx   = nil
      @current_pc = nil
      @fisk       = nil

      @blocks     = []
      @compile_requests = []
      @objects = []
      compile
    end

    def compile
      if @body.jit_func.to_i != 0
        return @body.jit_func.to_i
      end

      stats.compiled_methods += 1

      jit_head = jit_buffer.memory + jit_buffer.pos

      # ec is in rdi
      # cfp is in rsi

      # Write the prologue for book keeping
      Fisk.new { |_|
        _.mov(_.r10, _.uimm(stats.to_i))
          .inc(_.m64(_.r10, Stats.offsetof("executed_methods")))
          .mov(REG_BP, _.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
      }.write_to(jit_buffer)

      unless resume_compiling(0) == :abort
        @body.jit_func = jit_head
      end

      jit_head
    end

    private

    class Block
      attr_reader :entry_idx, :jit_position

      def initialize entry_idx, jit_position
        @entry_idx    = entry_idx
        @jit_position = jit_position
      end
    end

    def resume_compiling insn_idx, finish = nil
      @insn_idx   = insn_idx
      @blocks << Block.new(@insn_idx, jit_buffer.pos)
      enc = @body.iseq_encoded
      @current_pc = enc.to_i + (insn_idx * Fiddle::SIZEOF_VOIDP)

      while(insn = @insns[@insn_idx])
        name   = rb.insn_name(insn)
        len    = rb.insn_len(insn)
        params = @insns[@insn_idx + 1, len - 1]

        if $DEBUG
          puts "#{@insn_idx} compiling #{name} #{sprintf("%#x", @iseq.to_i)}"
        end
        if respond_to?("handle_#{name}", true)
          if $DEBUG
            Fisk.new { |_| print_str(_, "RT #{@insn_idx} #{name} #{sprintf("%#x", @iseq.to_i)}\n") }.write_to(jit_buffer)
          end
          @fisk = Fisk.new
          v = send("handle_#{name}", *params)
          if v == :quit
            make_exit(name, @current_pc, @temp_stack.dup).write_to jit_buffer
            break
          end
          if v == :abort
            make_exit(name, @current_pc, @temp_stack.dup).write_to jit_buffer
            return v
          end
          @fisk.release_all_registers
          @fisk.assign_registers(SCRATCH_REGISTERS, local: true)
          @fisk.write_to(jit_buffer)
          break if v == :stop

          if v == :continue
            @blocks << Block.new(@insn_idx + len, jit_buffer.pos)
          end
        else
          make_exit(name, @current_pc, @temp_stack.dup).write_to jit_buffer
          break
        end

        @insn_idx += len
        @current_pc += len * Fiddle::SIZEOF_VOIDP
      end
    end

    def flush
      @fisk.release_all_registers
      @fisk.assign_registers(SCRATCH_REGISTERS, local: true)
      @fisk.write_to(jit_buffer)
      @fisk = Fisk.new
    end

    def current_insn
      @insns[@insn_idx]
    end

    def insn_name
      rb.insn_name current_insn
    end

    def current_pc
      @current_pc
    end

    def next_idx
      @insn_idx + rb.insn_len(current_insn)
    end

    def next_pc
      len = rb.insn_len(current_insn)
      @current_pc + len * Fiddle::SIZEOF_VOIDP
    end

    def jit_buffer
      @jit.jit_buffer
    end

    def exits; @jit.exit_code; end

    def make_exit exit_insn_name, exit_pc, temp_stack
      jump_addr = exits.make_exit(exit_insn_name, exit_pc, temp_stack)
      Fisk.new { |_|
        _.mov(_.r10, _.uimm(jump_addr))
          .jmp(_.r10)
      }
    end

    CallCompileRequest = Struct.new(:call_info, :patch_loc, :return_loc, :overflow_exit, :temp_stack, :current_pc, :next_pc)

    def handle_opt_send_without_block call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      # only handle simple methods
      #return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      compile_request = CallCompileRequest.new
      compile_request.call_info = ci
      compile_request.overflow_exit = exits.make_exit("opt_send_without_block", current_pc, @temp_stack.dup)
      compile_request.temp_stack = @temp_stack.dup
      compile_request.current_pc = current_pc
      compile_request.next_pc = next_pc

      @compile_requests << Fiddle::Pinned.new(compile_request)

      deferred = @jit.deferred_call(@temp_stack) do |__, return_loc|
        __.with_register "reg_sp" do |temp|
          # Convert the SP to a Ruby integer
          __.mov(temp, __.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
          __.shl(temp, __.uimm(1))
            .add(temp, __.uimm(1))

          call_cfunc rb.symbol_address("rb_funcall"), [
            __.uimm(Fiddle.dlwrap(self)),
            __.uimm(CFuncs.rb_intern("compile_method_call")),
            __.uimm(2),
            temp,
            __.uimm(Fiddle.dlwrap(compile_request)),
          ], __

          __.mov(temp, __.uimm(return_loc))
            .jmp(temp)
        end
      end

      __.lazy { |pos|
        compile_request.patch_loc = pos
        deferred.call jit_buffer.memory + pos
      }

      # Jump in to the deferred compiler
      tmp = __.register
      __.mov(tmp, __.uimm(deferred.entry))
        .jmp(tmp)
      __.release_register tmp

      __.lazy { |pos| compile_request.return_loc = pos }

      (ci.vm_ci_argc + 1).times { @temp_stack.pop }

      # The method call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)
      __.pop(REG_BP)
      __.cmp(__.rax, __.uimm(Qundef))
      __.jne(__.label(:continue))
      __.ret
      __.put_label(:continue)
      __.mov(loc, __.rax)
    end

    def topn stack, i
      Fiddle::Pointer.new(stack - (Fiddle::SIZEOF_VOIDP * (i + 1))).ptr
    end

    def check_vm_stack_overflow __, compile_request, local_size, stack_max
      temp_stack = compile_request.temp_stack

      # /* check stack overflow */
      # CHECK_VM_STACK_OVERFLOW0(cfp, sp, local_size + stack_max);
      margin = ((local_size + stack_max) * Fiddle::SIZEOF_VOIDP) + RbControlFrameStruct.size
      __.with_register do |tmp|
        __.lea(tmp, __.m(temp_stack.+(margin + RbCallableMethodEntryT.size)))
          .cmp(REG_CFP, tmp)
          .jg(__.label(:continue))
          .mov(tmp, __.uimm(compile_request.overflow_exit))
          .jmp(tmp)
          .put_label(:continue)
      end
    end

    def vm_push_frame ec, iseq, type, _self, specval, cref_or_me, pc, sp, local_size, stack_max, compile_request, argc, __
      check_vm_stack_overflow __, compile_request, local_size, stack_max

      Runtime.new(__) do |rt|
        sp_ptr = rt.pointer sp
        ec_ptr = rt.pointer REG_EC, RbExecutionContextT
        cfp_ptr = rt.pointer REG_CFP, RbControlFrameStruct

        # rb_control_frame_t *const cfp = RUBY_VM_NEXT_CONTROL_FRAME(ec->cfp);
        cfp_ptr.sub # like -- in C

        # FIXME: Initialize local variables to nil
        # for (int i=0; i < local_size; i++) {
        #     *sp++ = Qnil;
        # }

        # /* setup ep with managing data */
        # *sp++ = cref_or_me; /* ep[-2] / Qnil or T_IMEMO(cref) or T_IMEMO(ment) */
        # *sp++ = specval     /* ep[-1] / block handler or prev env ptr */;
        # *sp++ = type;       /* ep[-0] / ENV_FLAGS */
        sp_ptr[0] = cref_or_me
        sp_ptr[1] = specval
        sp_ptr[2] = type

        # /* setup new frame */
        # *cfp = (const struct rb_control_frame_struct) {
        #     .pc         = pc,
        #     .sp         = sp,
        #     .iseq       = iseq,
        #     .self       = self,
        #     .ep         = sp - 1,
        #     .block_code = NULL,
        #     .__bp__     = sp,
        #     .bp_check   = sp,
        #     .jit_return = NULL
        # };
        cfp_ptr.pc = pc

        sp_ptr.with_ref(3 + local_size) do |new_sp|
          cfp_ptr.sp     = new_sp
          cfp_ptr.__bp__ = new_sp

          new_sp.sub
          cfp_ptr.ep     = new_sp
        end

        cfp_ptr.iseq = iseq
        cfp_ptr.self = _self
        cfp_ptr.block_code = 0

        # ec->cfp = cfp;
        ec_ptr.cfp = cfp_ptr
      end
    end

    def compile_jump stack, req
      target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }

      unless target_block
        resume_compiling req.jump_idx
        target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }
      end

      pos = jit_buffer.pos
      rel_jump = 0xCAFE
      2.times do
        jit_buffer.seek(req.patch_jump, IO::SEEK_SET)
        Fisk.new { |__| __.jmp(__.rel32(rel_jump)) }.write_to(jit_buffer)
        rel_jump = target_block.jit_position - jit_buffer.pos
      end
      jit_buffer.seek(pos, IO::SEEK_SET)
      @compile_requests.delete_if { |x| x.ref == req }
    end

    def patch_source_jump jit_buffer, compile_request
      ## Patch the source location to jump here
      current_pos = jit_buffer.pos
      jump_loc = jit_buffer.memory + current_pos
      fisk = Fisk.new { |__|
        __.with_register do |tmp|
          __.mov(tmp, __.uimm(jump_loc.to_i))
          __.jmp(tmp)
        end
      }

      fisk.assign_registers(SCRATCH_REGISTERS, local: true)

      jit_buffer.seek compile_request.patch_loc, IO::SEEK_SET
      fisk.write_to(jit_buffer)
      jit_buffer.seek current_pos, IO::SEEK_SET
    end

    def compile_method_call stack, compile_request
      ci = compile_request.call_info
      mid = ci.vm_ci_mid
      argc = ci.vm_ci_argc
      recv = topn(stack, ci.vm_ci_argc)

      ## Compile the target method
      klass = RBasic.new(recv).klass # FIXME: this only works on heap allocated objects

      cme = RbCallableMethodEntryT.new(rb.rb_callable_method_entry(klass, mid))
      method_definition = RbMethodDefinitionStruct.new(cme.def)

      # If we find an iseq method, compile it, even if we don't enter.
      if method_definition.type == VM_METHOD_TYPE_ISEQ
        iseq_ptr = RbMethodDefinitionStruct.new(cme.def).body.iseq.iseqptr.to_i
        iseq = RbISeqT.new(iseq_ptr)
        @jit.compile_iseq_t iseq_ptr
      end

      # Bail on any method calls that aren't "simple".  Not handling *args,
      # kwargs, etc right now
      #if ci.vm_ci_flag & VM_CALL_ARGS_SPLAT > 0
      unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE
        patch_source_jump jit_buffer, compile_request

        fisk = Fisk.new do |__|
          __.with_register do |tmp|
            __.mov(tmp, __.uimm(compile_request.overflow_exit))
              .jmp(tmp)
          end
        end
        fisk.assign_registers(SCRATCH_REGISTERS, local: true)
        fisk.write_to(jit_buffer)

        return
      end

      __ = Fisk.new

      case method_definition.type
      when VM_METHOD_TYPE_CFUNC
        cfunc = RbMethodDefinitionStruct.new(cme.def).body.cfunc
        param_size = if cfunc.argc == -1
                       argc
                     elsif cfunc.argc < 0
                       raise NotImplementedError
                     else
                       cfunc.argc
                     end

        frame_type = VM_FRAME_MAGIC_CFUNC | VM_FRAME_FLAG_CFRAME | VM_ENV_FLAG_LOCAL;

        patch_source_jump jit_buffer, compile_request

        temp_stack = compile_request.temp_stack
        __.with_register do |argv|
          # Write next PC to CFP
          __.mov(argv, __.uimm(compile_request.next_pc))
            .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), argv)

          idx = temp_stack.size - (argc + 1)
          x = temp_stack.peek(idx).loc
          ## Pop params and self from the stack
          __.lea(argv, __.m(REG_BP, x.displacement))
            .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), argv)
          __.lea(argv, __.m(REG_BP, ((temp_stack.size - argc) + param_size + 1) * Fiddle::SIZEOF_VOIDP))

          vm_push_frame(REG_EC,
                        0,
                        frame_type,
                        recv,
                        0, #ci.block_handler,
                        cme,
                        0,
                        argv,
                        0,
                        0,
                        compile_request,
                        argc,
                        __)

          __.lea(argv, __.m(REG_BP, ((temp_stack.size - argc)) * Fiddle::SIZEOF_VOIDP))

          call_cfunc cfunc.invoker.to_i, [__.uimm(recv), __.uimm(argc), argv, __.uimm(cfunc.func.to_i)], __
          __.push(REG_BP) # Caller expects to pop REG_BP
          __.mov(argv, __.uimm(jit_buffer.memory + compile_request.return_loc))
            .push(argv)
        end


        __.add(REG_CFP, __.uimm(RbControlFrameStruct.size))
        __.mov __.m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP
        __.ret

      when VM_METHOD_TYPE_ISEQ
        # `vm_call_iseq_setup`
        param_size = iseq.body.param.size
        local_size = iseq.body.local_table_size
        opt_pc     = 0 # we don't handle optional parameters rn

        # `vm_call_iseq_setup_2` FIXME: we need to deal with TAILCALL
        # `vm_call_iseq_setup_normal` FIXME: we need to deal with TAILCALL

        temp_stack = compile_request.temp_stack

        # pop locals and recv off the stack
        #(ci.vm_ci_argc + 1).times { @temp_stack.pop }

        patch_source_jump jit_buffer, compile_request

        argv = __.register "tmp"

        # Write next PC to CFP
        __.mov(argv, __.uimm(compile_request.next_pc))
          .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), argv)

        # Pop params and self from the stack
        x = temp_stack - ((argc + 1) * Fiddle::SIZEOF_VOIDP)
        __.lea(argv, __.m(REG_BP, x.displacement))
          .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), argv)

        __.lea(argv, __.m(REG_BP, (temp_stack.size - argc + param_size) * Fiddle::SIZEOF_VOIDP))

        # `vm_call_iseq_setup_normal`

        # `vm_push_frame`
        vm_push_frame REG_EC,
          iseq_ptr,
          VM_FRAME_MAGIC_METHOD | VM_ENV_FLAG_LOCAL,
          recv,
          0, #ci.block_handler,
          cme,
          iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
          argv,
          local_size - param_size,
          iseq.body.stack_max,
          compile_request,
          argc,
          __

        ## Write out the method call

        ## Push the return location on the machine stack.  `leave` will `ret` here
        __.mov(argv, __.uimm(jit_buffer.memory + compile_request.return_loc))
          .push(REG_BP)
          .push(argv)
          .mov(argv, __.uimm(iseq.body))
          .mov(argv, __.m64(argv, iseq.body.class.offsetof("jit_func")))
          .jmp(argv)

        __.release_register argv
      when VM_METHOD_TYPE_BMETHOD
        opt_pc     = 0 # we don't handle optional parameters rn
        proc_obj = RbMethodDefinitionStruct.new(cme.def).body.bmethod.proc
        proc = RData.new(proc_obj).data
        rb_block_t    = RbProcT.new(proc).block
        if rb_block_t.type != rb.c("block_type_iseq")
          raise NotImplementedError
        end
        captured = rb_block_t.as.captured
        _self = recv
        type = VM_FRAME_MAGIC_BLOCK
        iseq = RbISeqT.new(captured.code.iseq)

        param_size = iseq.body.param.size

        @jit.compile_iseq_t iseq.to_i

        patch_source_jump jit_buffer, compile_request

        temp_stack = compile_request.temp_stack

        __.with_register do |argv|
          __.mov(argv, __.uimm(compile_request.next_pc))
            .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), argv)

          # Pop params and self from the stack
          x = temp_stack.-((argc + 1) * Fiddle::SIZEOF_VOIDP)
          __.lea(argv, __.m(REG_BP, x.displacement))
            .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), argv)

          __.lea(argv, __.m(REG_BP, (temp_stack.size - argc + param_size) * Fiddle::SIZEOF_VOIDP))

          vm_push_frame REG_EC,
            iseq.to_i,
            type | VM_FRAME_FLAG_BMETHOD,
            recv,
            VM_GUARDED_PREV_EP(captured.ep),
            cme,
            iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
            argv,
            iseq.body.local_table_size - param_size,
            iseq.body.stack_max,
            compile_request,
            argc,
            __

          __.mov(argv, __.uimm(jit_buffer.memory + compile_request.return_loc))
            .push(REG_BP)
            .push(argv)
            .mov(argv, __.uimm(iseq.body))
            .mov(argv, __.m64(argv, iseq.body.class.offsetof("jit_func")))
            .jmp(argv)
        end
      else
        patch_source_jump jit_buffer, compile_request

        __.with_register do |argv|
          __.mov(argv, __.uimm(compile_request.overflow_exit))
            .jmp(argv)
        end
      end

      __.assign_registers(SCRATCH_REGISTERS, local: true)
      __.write_to(jit_buffer)
    end

    def save_regs fisk = __
      fisk.push(REG_EC)
        .push(REG_CFP)
        .push(REG_BP)
    end

    def restore_regs fisk = __
      fisk.pop(REG_BP)
        .pop(REG_CFP)
        .pop(REG_EC)
    end

    def handle_duparray ary
      write_loc = @temp_stack.push(:object, type: T_ARRAY)

      call_cfunc rb.symbol_address("rb_ary_resurrect"), [__.uimm(ary)]

      __.mov write_loc, __.rax
    end

    class BranchUnless < Struct.new(:jump_idx, :patch_jump, :temp_stack)
    end

    def handle_branchunless dst
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      jump_pc = @insn_idx + dst + len

      target_jump_block = @blocks.find { |b| b.entry_idx == jump_pc }

      if target_jump_block
        raise NotImplementedError, "FIXME"
      end

      next_pc = self.next_pc
      target_next_block = @blocks.find { |b| b.entry_idx == next_pc }

      if target_next_block
        raise NotImplementedError, "FIXME"
      end

      patch_request = BranchUnless.new jump_pc

      deferred = @jit.deferred_call(@temp_stack) do |__, return_loc|
        call_cfunc rb.symbol_address("rb_funcall"), [
          __.uimm(Fiddle.dlwrap(self)),
          __.uimm(CFuncs.rb_intern("compile_branchunless")),
          __.uimm(1),
          __.uimm(Fiddle.dlwrap(patch_request))
        ], __

        __.with_register do |tmp|
          __.mov(tmp, __.uimm(return_loc))
            .jmp(tmp)
        end
      end

      flush

      deferred.call(jit_buffer.memory + jit_buffer.pos)

      __.test(@temp_stack.pop, __.imm(~Qnil))

      patch_request.temp_stack = @temp_stack.dup

      flush

      patch_request.patch_jump = jit_buffer.pos

      pos = jit_buffer.pos
      rel_jump = 0xCAFE
      2.times do
        jit_buffer.seek(pos, IO::SEEK_SET)
        Fisk.new { |__| __.jz(__.rel32(rel_jump)) }.write_to(jit_buffer)
        rel_jump = deferred.entry.to_i - (jit_buffer.memory.to_i + jit_buffer.pos)
      end

      :continue # create a new block and keep compiling
    end

    def compile_branchunless req
      target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }

      unless target_block
        resume_compiling req.jump_idx
        target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }
      end

      pos = jit_buffer.pos
      rel_jump = 0xCAFE
      2.times do
        jit_buffer.seek(req.patch_jump, IO::SEEK_SET)
        Fisk.new { |__| __.jz(__.rel32(rel_jump)) }.write_to(jit_buffer)
        rel_jump = target_block.jit_position - jit_buffer.pos
      end
      jit_buffer.seek(pos, IO::SEEK_SET)
      @compile_requests.delete_if { |x| x.ref == req }
    end

    class BranchIf < Struct.new(:jump_idx, :next_idx, :patch_jump, :patch_next)
    end

    def compile_branchif stack, req, jump_p
      pos = jit_buffer.pos

      if jump_p
        target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }

        unless target_block
          resume_compiling req.jump_idx
          target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }
        end

        pos = jit_buffer.pos
        rel_jump = 0xCAFE
        2.times do
          jit_buffer.seek(req.patch_jump, IO::SEEK_SET)
          Fisk.new { |__| __.jnz(__.rel32(rel_jump)) }.write_to(jit_buffer)
          rel_jump = target_block.jit_position - jit_buffer.pos
        end
      else
        target_block = @blocks.find { |b| b.entry_idx == req.next_idx }

        unless target_block
          resume_compiling req.next_idx
          target_block = @blocks.find { |b| b.entry_idx == req.next_idx }
        end

        rel_jump = 0xCAFE
        2.times do
          jit_buffer.seek(req.patch_next, IO::SEEK_SET)
          Fisk.new { |__| __.jmp(__.rel32(rel_jump)) }.write_to(jit_buffer)
          rel_jump = target_block.jit_position - jit_buffer.pos
        end
      end

      jit_buffer.seek(pos, IO::SEEK_SET)
    end

    def handle_branchif dst
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      jump_idx = @insn_idx + dst + len

      # if this is a backwards jump, check interrupts
      if jump_idx < @insn_idx
        exit_addr = exits.make_exit(insn_name, current_pc, @temp_stack.dup)

        __.with_register do |tmp|
          __.mov(tmp, __.m64(REG_EC, RbExecutionContextT.offsetof("interrupt_mask")))
            .not(tmp)
            .test(__.m64(REG_EC, RbExecutionContextT.offsetof("interrupt_flag")), tmp)
            .jz(__.label(:continue))
            .mov(tmp, __.uimm(exit_addr))
            .jmp(tmp)
            .put_label(:continue)
        end
      end

      target_jump_block = @blocks.find { |b| b.entry_idx == jump_idx }

      patch_request = BranchIf.new jump_idx, next_idx
      @compile_requests << Fiddle::Pinned.new(patch_request)

      deferred = @jit.deferred_call(@temp_stack) do |__, return_loc|
        __.with_register "reg_sp" do |temp|
          # Convert the SP to a Ruby integer
          __.mov(temp, __.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
          __.shl(temp, __.uimm(1))
            .add(temp, __.uimm(1))

          call_cfunc rb.symbol_address("rb_funcall"), [
            __.uimm(Fiddle.dlwrap(self)),
            __.uimm(CFuncs.rb_intern("compile_branchif")),
            __.uimm(3),
            temp,
            __.uimm(Fiddle.dlwrap(patch_request)),
            __.rax
          ], __

          __.mov(temp, __.uimm(return_loc))
            .jmp(temp)
        end
      end

      __.lazy { |pos|
        deferred.call jit_buffer.memory + pos
      }

      __.test(@temp_stack.pop, __.imm(~Qnil))
      if target_jump_block
        before_jump = nil

        __.lazy { |pos| before_jump = pos }
        __.jnz(__.rel32(0xCAFE))
        __.lazy { |pos|
          jit_buffer.seek(before_jump, IO::SEEK_SET)
          Fisk.new { |f|
            f.jnz(f.rel32(target_jump_block.jit_position - pos))
          }.write_to(jit_buffer)
          raise unless jit_buffer.pos == pos
        }
      else
        __.lazy { |pos| patch_request.patch_jump = pos }
        # Jump if value is true
        __.jnz(__.label(:patch_request))
      end
      __.lazy { |pos| patch_request.patch_next = pos }

      #p CONTINUE: target_continue_block
      __.with_register do |tmp|
        __.mov(__.rax, __.imm(Qfalse))
        __.mov(tmp, __.uimm(deferred.entry))
        __.jmp(tmp)
      end

      __.put_label(:patch_request)

      __.with_register do |tmp|
        __.mov(__.rax, __.imm(Qtrue))
        __.mov(tmp, __.uimm(deferred.entry))
        __.jmp(tmp)
      end

      :stop
    end

    def handle_opt_getinlinecache dst, ic
      ic = IseqInlineConstantCache.new ic
      if ic.entry.to_ptr.null?
        @body.jit_func = CACHE_BUSTERS.memory.to_i
        return :abort
      end

      ice = ic.entry
      if ice.ic_serial != RubyVM.stat(:global_constant_state)
        @body.jit_func = CACHE_BUSTERS.memory.to_i
        return :abort
      end

      loc = @temp_stack.push(:cache_get, type: rb.RB_BUILTIN_TYPE(ice.value))

      # FIXME: This should be a weakref probably
      @objects << Fiddle::Pinned.new(Fiddle.dlunwrap(ice.value))

      ary_head = Fiddle::Pointer.new(CONST_WATCHERS)
      watcher_count = ary_head[0, Fiddle::SIZEOF_VOIDP].unpack1("l!")
      watchers = ary_head[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP * watcher_count].unpack("l!#{watcher_count}")
      unless watchers.include? @body.to_i
        watchers << @body.to_i
        ary_head[0, Fiddle::SIZEOF_VOIDP] = [watchers.length].pack("q")
        buf = watchers.pack("q*")
        ary_head[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP * watchers.length] = buf
      end

      __.with_register do |tmp|
        __.mov(tmp, __.uimm(ice.value))
          .mov(loc, tmp)
      end

      handle_jump dst
    end

    class HandleJump < Struct.new(:jump_idx, :patch_jump)
    end

    def handle_jump dst
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      dst = @insn_idx + dst + len

      patch_request = HandleJump.new dst
      @compile_requests << Fiddle::Pinned.new(patch_request)

      deferred = @jit.deferred_call(@temp_stack) do |__, return_loc|
        __.with_register "reg_sp" do |temp|
          # Convert the SP to a Ruby integer
          __.mov(temp, __.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
          __.shl(temp, __.uimm(1))
            .add(temp, __.uimm(1))

          call_cfunc rb.symbol_address("rb_funcall"), [
            __.uimm(Fiddle.dlwrap(self)),
            __.uimm(CFuncs.rb_intern("compile_jump")),
            __.uimm(2),
            temp,
            __.uimm(Fiddle.dlwrap(patch_request)),
          ], __

          __.mov(temp, __.uimm(return_loc))
            .jmp(temp)
        end
      end

      __.lazy { |pos|
        deferred.call jit_buffer.memory + pos
        patch_request.patch_jump = pos
      }

      __.with_register do |tmp|
        __.mov(tmp, __.uimm(deferred.entry))
        __.jmp(tmp)
      end

      :stop
    end

    def handle_putnil
      loc = @temp_stack.push(:nil, type: T_NIL)
      __.mov loc, __.uimm(Qnil)
    end

    def handle_pop
      @temp_stack.pop
    end

    def handle_opt_minus call_data
      ts = @temp_stack

      exit_addr = exits.make_exit("opt_minus", current_pc, @temp_stack.dup)

      # Generate runtime checks if we need them
      2.times do |i|
        idx = ts.size - i - 1
        if ts.peek(idx).type != T_FIXNUM
          # Is the argument a fixnum?
          __.test(ts.peek(idx).loc, __.uimm(rb.c("RUBY_FIXNUM_FLAG")))
            .jz(__.label(:quit!))
        end
      end

      rhs_loc = ts.pop
      lhs_loc = ts.pop

      tmp = __.rax

      __.mov(tmp, lhs_loc)
        .sub(tmp, rhs_loc)
        .jo(__.label(:quit!))
        .add(tmp, __.uimm(1))

      write_loc = ts.push(:object, type: T_FIXNUM)

      __.mov(write_loc, __.rax)

      __.jmp(__.label(:done))

      __.put_label(:quit!)
        .mov(__.rax, __.uimm(exit_addr))
        .jmp(__.rax)

      __.put_label(:done)
    end

    def handle_opt_plus call_data
      ts = @temp_stack

      exit_addr = exits.make_exit("opt_plus", current_pc, @temp_stack.dup)

      # Generate runtime checks if we need them
      2.times do |i|
        idx = ts.size - i - 1
        if ts.peek(idx).type != T_FIXNUM
          # Is the argument a fixnum?
          __.test(ts.peek(idx).loc, __.uimm(rb.c("RUBY_FIXNUM_FLAG")))
            .jz(__.label(:quit!))
        end
      end

      rhs_loc = ts.pop
      lhs_loc = ts.pop

      tmp = __.rax

      __.mov(tmp, lhs_loc)
        .sub(tmp, __.uimm(1))
        .add(tmp, rhs_loc)
        .jo(__.label(:quit!))

      write_loc = ts.push(:object, type: T_FIXNUM)

      __.mov(write_loc, __.rax)

      __.jmp(__.label(:done))

      __.put_label(:quit!)
        .mov(__.rax, __.uimm(exit_addr))
        .jmp(__.rax)

      __.put_label(:done)
    end

    # Guard stack types. They need to be in "stack" order (backwards)
    def guard_two_fixnum
      ts = @temp_stack

      exit_addr = nil

      # Generate runtime checks if we need them
      2.times do |i|
        idx = ts.size - i - 1
        if ts.peek(idx).type != T_FIXNUM
          exit_addr ||= exits.make_exit(insn_name, current_pc, @temp_stack.dup)

          # Is the argument a fixnum?
          __.test(ts.peek(idx).loc, __.uimm(rb.c("RUBY_FIXNUM_FLAG")))
            .jz(__.label(:quit!))
        end
      end

      yield

      # If we needed to generate runtime checks then add the labels and jumps
      if exit_addr
        __.jmp(__.label(:done))

        __.put_label(:quit!)
          .mov(__.rax, __.uimm(exit_addr))
          .jmp(__.rax)

        __.put_label(:done)
      end
    end

    def compare_fixnum
      guard_two_fixnum do
        __.with_register do |reg0|
          __.with_register do |reg1|
            rhs_loc = @temp_stack.pop
            lhs_loc = @temp_stack.pop

            # Copy the LHS and RHS in to registers
            __.xor(reg0, reg0)
              .mov(reg1, lhs_loc)

            # Compare them
            __.cmp(reg1, rhs_loc)

            # Conditionally move based on the comparison
            __.mov(reg1, __.uimm(Qtrue))

            yield reg0, reg1

            # Push the result on the stack
            __.mov(@temp_stack.push(:boolean), reg0)
          end
        end
      end
    end

    def handle_opt_gt call_data
      compare_fixnum { |reg0, reg1| __.cmovg(reg0, reg1) }
    end

    def handle_opt_ge call_data
      compare_fixnum { |reg0, reg1| __.cmovge(reg0, reg1) }
    end

    def handle_opt_lt call_data
      compare_fixnum { |reg0, reg1| __.cmovl(reg0, reg1) }
    end

    def handle_opt_le call_data
      compare_fixnum { |reg0, reg1| __.cmovle(reg0, reg1) }
    end

    def handle_putobject_INT2FIX_1_
      loc = @temp_stack.push(:literal, type: T_FIXNUM)
      __.mov loc, __.uimm(0x3)
    end

    def handle_putobject_INT2FIX_0_
      loc = @temp_stack.push(:literal, type: T_FIXNUM)
      __.mov loc, __.uimm(0x1)
    end

    def handle_setlocal_WC_0 idx
      loc = @temp_stack.pop

      addr = exits.make_exit("setlocal_WC_0", current_pc, @temp_stack.dup)

      reg_ep = __.register "ep"
      reg_local = __.register "local"

      # Set the local value to the EP
      __.mov(reg_ep, __.m64(REG_CFP, RbControlFrameStruct.offsetof("ep")))
        .test(__.m64(reg_ep, Fiddle::SIZEOF_VOIDP * VM_ENV_DATA_INDEX_FLAGS),
                       __.uimm(rb.c("VM_ENV_FLAG_WB_REQUIRED")))
        .jz(__.label(:continue))
        .mov(reg_local, __.uimm(addr))
        .jmp(reg_local)
        .put_label(:continue)
        .mov(reg_local, loc)
        .mov(__.m64(reg_ep, -(Fiddle::SIZEOF_VOIDP * idx)), reg_local)
    end

    def handle_getlocal_WC_0 idx
      #level = 0
      loc = @temp_stack.push(:local)

      reg_ep = __.register "ep"
      reg_local = __.register "local"

      # Get the local value from the EP
      __.mov(reg_ep, __.m64(REG_CFP, RbControlFrameStruct.offsetof("ep")))
        .sub(reg_ep, __.uimm(Fiddle::SIZEOF_VOIDP * idx))
        .mov(reg_local, __.m64(reg_ep))
        .mov(loc, reg_local)
    end

    def handle_putself
      loc = @temp_stack.push(:self)

      reg_self = __.register "self"

      # Get self from the CFP
      __.mov(reg_self, __.m64(REG_CFP, RbControlFrameStruct.offsetof("self")))
        .mov(loc, reg_self)
    end

    def handle_putobject literal
      loc = if rb.RB_FIXNUM_P(literal)
              @temp_stack.push(:literal, type: T_FIXNUM)
            else
              @temp_stack.push(:literal)
            end

      reg = __.register
      __.mov reg, __.uimm(literal)
      __.mov loc, reg
    end

    # `leave` instruction
    def handle_leave
      loc = @temp_stack.pop

      # FIXME: We need to check interrupts and exit
      # Copy top value from the stack in to rax
      __.mov __.rax, loc

      # Pop the frame from the stack
      __.add(REG_CFP, __.uimm(RbControlFrameStruct.size))

      # Write the frame pointer back to the ec
      __.mov __.m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP
      __.ret
      :continue
    end

    def handle_splatarray flag
      raise NotImplementedError unless flag == 0

      pop_loc = @temp_stack.pop
      push_loc = @temp_stack.push(:object, type: T_ARRAY)

      vm_splat_array pop_loc, push_loc
    end

    def vm_splat_array read_loc, store_loc
      call_cfunc rb.symbol_address("rb_check_to_array"), [read_loc]

      # If it returned nil, make a new array
      __.cmp(__.rax, __.uimm(Qnil))
        .jne(__.label(:continue))

      call_cfunc rb.symbol_address("rb_ary_new_from_args"), [__.uimm(1), __.rax]

      __.put_label(:continue)
        .mov(store_loc, __.rax)
    end

    # Call a C function at `func_loc` with `params`. Return value will be in RAX
    def call_cfunc func_loc, params, fisk = __
      raise NotImplementedError, "too many parameters" if params.length > 6
      raise "No function location" unless func_loc > 0

      save_regs fisk
      params.each_with_index do |param, i|
        fisk.mov(Fisk::Registers::CALLER_SAVED[i], param)
      end
      fisk.mov(fisk.rax, fisk.uimm(func_loc))
        .call(fisk.rax)
      restore_regs fisk
    end

    def rb; Internals; end

    def member_size struct, member
      TenderJIT.member_size(struct, member)
    end

    def break fisk = __
      fisk.int fisk.lit(3)
    end

    def print_str fisk, string
      fisk.jmp(fisk.label(:after_bytes))
      pos = nil
      fisk.lazy { |x| pos = x; string.bytes.each { |b| jit_buffer.putc b } }
      fisk.put_label(:after_bytes)
      save_regs fisk
      fisk.mov fisk.rdi, fisk.uimm(1)
      fisk.lazy { |x|
        fisk.mov fisk.rsi, fisk.uimm(jit_buffer.memory + pos)
      }
      fisk.mov fisk.rdx, fisk.uimm(string.bytesize)
      fisk.mov fisk.rax, fisk.uimm(0x02000004)
      fisk.syscall
      restore_regs fisk
    end

    def VM_GUARDED_PREV_EP ep
      ep.to_i | 0x01
    end
  end
end
