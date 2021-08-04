require "tenderjit/temp_stack"

class TenderJIT
  class ISEQCompiler
    attr_reader :stats

    def initialize stats, jit
      @stats      = stats
      @jit        = jit
      @temp_stack = TempStack.new
    end

    def __
      @fisk
    end

    def compile addr
      body  = RbISeqT.new(addr).body

      if body.jit_func.to_i != 0
        return body.jit_func.to_i
      end

      @insns = Fiddle::CArray.unpack(body.iseq_encoded, body.iseq_size, Fiddle::TYPE_VOIDP)

      stats.compiled_methods += 1

      jit_head = jit_buffer.memory + jit_buffer.pos
      cb = CodeBlock.new jit_head

      # ec is in rdi
      # cfp is in rsi

      # Write the prologue for book keeping
      Fisk.new { |_|
        _.mov(_.r10, _.uimm(stats.to_i))
          .inc(_.m64(_.r10, Stats.offsetof("executed_methods")))
          .mov(REG_SP, _.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
      }.write_to(jit_buffer)

      @current_pc = body.iseq_encoded.to_i

      scratch_registers = [
        Fisk::Registers::R9,
        Fisk::Registers::R10,
      ]

      @insn_idx = 0
      while(insn, branch = @insns[@insn_idx])
        branch.patch(jit_buffer) if branch
        name   = rb.insn_name(insn)
        len    = rb.insn_len(insn)
        params = @insns[@insn_idx + 1, len - 1]

        if respond_to?("handle_#{name}", true)
          Fisk.new { |_| print_str(_, name + "\n") }.write_to(jit_buffer)
          @fisk = Fisk.new
          send("handle_#{name}", *params)
          @fisk.release_all_registers
          @fisk.assign_registers(scratch_registers, local: true)
          @fisk.write_to(jit_buffer)
        else
          make_exit(name, @current_pc, @temp_stack.size).write_to jit_buffer
          break
        end

        @insn_idx += len
        @current_pc += len * Fiddle::SIZEOF_VOIDP
      end

      cb.finish = jit_buffer.memory + jit_buffer.pos
      ary = nil
      cov_ptr = body.variable.coverage
      if cov_ptr == 0
        ary = []
        body.variable.coverage = Fiddle.dlwrap(ary)
      else
        ary = Fiddle.dlunwrap(cov_ptr)
      end

      # COVERAGE_INDEX_LINES is 0
      # COVERAGE_INDEX_BRANCHES is 1
      # 2 is unused so we'll use it. :D
      (ary[2] ||= []) << cb

      body.jit_func = jit_head

      jit_head.to_i
    end

    private

    def current_insn
      insn, = @insns[@insn_idx]
      insn
    end

    def insn_name
      rb.insn_name current_insn
    end

    def current_pc
      @current_pc
    end

    def next_pc
      len = rb.insn_len(current_insn)
      @current_pc + len * Fiddle::SIZEOF_VOIDP
    end

    def jit_buffer
      @jit.jit_buffer
    end

    def exits; @jit.exit_code; end

    def make_exit exit_insn_name, exit_pc, exit_sp
      jump_addr = exits.make_exit(exit_insn_name, exit_pc, exit_sp)
      Fisk.new { |_|
        _.mov(_.r10, _.uimm(jump_addr))
          .jmp(_.r10)
      }
    end

    CallCompileRequest = Struct.new(:call_info, :patch_loc, :return_loc, :overflow_exit, :temp_stack, :current_pc, :next_pc)
    COMPILE_REQUSTS = []

    def handle_opt_send_without_block call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      # only handle simple methods
      #return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      compile_request = CallCompileRequest.new
      compile_request.call_info = ci
      compile_request.overflow_exit = exits.make_exit("opt_send_without_block", current_pc, @temp_stack.size)
      compile_request.temp_stack = @temp_stack.dup
      compile_request.current_pc = current_pc
      compile_request.next_pc = next_pc

      COMPILE_REQUSTS << Fiddle::Pinned.new(compile_request)

      # Dup the temp stack so that later mutations won't impact "deferred" call
      ts = @temp_stack.dup

      deferred = @jit.deferred_call do |__, return_loc|
        # Flush the SP so that the next Ruby call will push a frame correctly
        ts.flush __

        __.with_register "reg_sp" do |temp|
          # Convert the SP to a Ruby integer
          __.mov(temp, __.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
          __.shl(temp, __.uimm(1))
            .add(temp, __.uimm(1))

          call_cfunc rb.symbol_address("rb_funcall"), [
            __.uimm(Fiddle.dlwrap(self)),
            __.uimm(rb.rb_intern("compile_method_call")),
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
      __.pop(REG_SP)
      __.cmp(__.rax, __.uimm(Qundef))
      __.jne(__.label(:continue))
      __.ret
      __.put_label(:continue)
      __.mov(loc, __.rax)
    end

    def topn stack, i
      Fiddle::Pointer.new(stack - (Fiddle::SIZEOF_VOIDP * (i + 1))).ptr
    end

    def vm_push_frame ec, iseq, type, _self, specval, cref_or_me, pc, sp, local_size, stack_max, compile_request, __
      # rb_control_frame_t *const cfp = RUBY_VM_NEXT_CONTROL_FRAME(ec->cfp);
      # We already have the CFP in a register, so lets just increment that
      __.sub(REG_CFP, __.uimm(RbControlFrameStruct.size))

      tmp = __.register

      temp_stack = compile_request.temp_stack

      # /* check stack overflow */
      # CHECK_VM_STACK_OVERFLOW0(cfp, sp, local_size + stack_max);
      margin = local_size + stack_max
      __.lea(tmp, __.m(temp_stack + (margin + RbCallableMethodEntryT.size)))
        .cmp(REG_CFP, tmp)
        .jg(__.label(:continue))
        .mov(tmp, __.uimm(compile_request.overflow_exit))
        .jmp(tmp)
        .put_label(:continue)

      # FIXME: Initialize local variables
      #p LOCAL_SIZE2: local_size

      # /* setup ep with managing data */
      __.mov(tmp, __.uimm(cref_or_me))
        .mov(__.m64(sp), tmp)

      __.mov(tmp, __.uimm(specval))
      __.mov(__.m64(sp, Fiddle::SIZEOF_VOIDP), tmp)

      __.mov(tmp, __.uimm(type))
      __.mov(__.m64(sp, 2 * Fiddle::SIZEOF_VOIDP), tmp)

      __.mov(tmp, __.uimm(pc))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), tmp)

      __.lea(tmp, __.m(sp, 3 * Fiddle::SIZEOF_VOIDP))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), tmp)
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("__bp__")), tmp)
        .sub(tmp, __.uimm(Fiddle::SIZEOF_VOIDP))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("ep")), tmp)

      __.mov(tmp, __.uimm(iseq))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("iseq")), tmp)
      __.mov(tmp, __.uimm(_self))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("self")), tmp)
      __.mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("block_code")), __.uimm(0))

      __.mov __.m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP
      __.release_register tmp
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

      if method_definition.type != rb.c("VM_METHOD_TYPE_ISEQ")
        current_pos = jit_buffer.pos
        jump_loc = jit_buffer.memory + current_pos

        ## Patch the source location to jump here
        fisk = Fisk.new
        fisk.mov(fisk.r10, fisk.uimm(jump_loc.to_i))
        fisk.jmp(fisk.r10)

        jit_buffer.seek compile_request.patch_loc, IO::SEEK_SET
        fisk.write_to(jit_buffer)
        jit_buffer.seek current_pos, IO::SEEK_SET

        __ = Fisk.new
        argv = __.register "tmp"

        __.mov(argv, __.uimm(compile_request.overflow_exit))
          .jmp(argv)

        __.release_all_registers
        __.assign_registers([__.r9, __.r10], local: true)
        __.write_to(jit_buffer)
        return
      end

      iseq_ptr = RbMethodDefinitionStruct.new(cme.def).body.iseq.iseqptr.to_i
      iseq = RbISeqT.new(iseq_ptr)
      entrance_addr = ISEQCompiler.new(stats, @jit).compile iseq_ptr

      # `vm_call_iseq_setup`
      param_size = iseq.body.param.size
      local_size = iseq.body.local_table_size
      opt_pc     = 0 # we don't handle optional parameters rn

      # `vm_call_iseq_setup_2` FIXME: we need to deal with TAILCALL
      # `vm_call_iseq_setup_normal` FIXME: we need to deal with TAILCALL

      temp_stack = compile_request.temp_stack

      # pop locals and recv off the stack
      #(ci.vm_ci_argc + 1).times { @temp_stack.pop }

      __ = Fisk.new
      argv = __.register "tmp"

      #if ci.vm_ci_flag & VM_CALL_ARGS_SPLAT > 0
      unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE
        current_pos = jit_buffer.pos
        jump_loc = jit_buffer.memory + current_pos
        ## Patch the source location to jump here
        fisk = Fisk.new
        fisk.mov(fisk.r10, fisk.uimm(jump_loc.to_i))
        fisk.jmp(fisk.r10)

        jit_buffer.seek compile_request.patch_loc, IO::SEEK_SET
        fisk.write_to(jit_buffer)
        jit_buffer.seek current_pos, IO::SEEK_SET

        __.mov(argv, __.uimm(compile_request.overflow_exit))
          .jmp(argv)

        __.release_all_registers
        __.assign_registers([__.r9, __.r10], local: true)
        __.write_to(jit_buffer)
        return
      end

      __.mov(argv, __.uimm(compile_request.next_pc))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), argv)

      # Pop params and self from the stack
      __.lea(argv, __.m(temp_stack - ((argc + 1) * Fiddle::SIZEOF_VOIDP)))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), argv)

      __.lea(argv, __.m(REG_SP, (temp_stack.size - argc + param_size) * Fiddle::SIZEOF_VOIDP))

      # `vm_call_iseq_setup_normal`

      # `vm_push_frame`
      vm_push_frame REG_EC,
                    iseq_ptr,
                    rb.c("VM_FRAME_MAGIC_METHOD") | rb.c("VM_ENV_FLAG_LOCAL"),
                    recv,
                    0, #ci.block_handler,
                    cme,
                    iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
                    argv,
                    local_size - param_size,
                    iseq.body.stack_max,
                    compile_request,
                    __

      current_pos = jit_buffer.pos
      jump_loc = jit_buffer.memory + current_pos

      ## Patch the source location to jump here
      fisk = Fisk.new
      fisk.mov(fisk.r10, fisk.uimm(jump_loc.to_i))
      fisk.jmp(fisk.r10)

      jit_buffer.seek compile_request.patch_loc, IO::SEEK_SET
      fisk.write_to(jit_buffer)
      jit_buffer.seek current_pos, IO::SEEK_SET

      ## Write out the method call

      ## Push the return location on the machine stack.  `leave` will `ret` here
      __.mov(argv, __.uimm(jit_buffer.memory + compile_request.return_loc))
        .push(REG_SP)
        .push(argv)
        .mov(argv, __.uimm(entrance_addr))
        .jmp(argv)

      __.release_register argv

      __.release_all_registers
      __.assign_registers([__.r9, __.r10], local: true)
      __.write_to(jit_buffer)
    end

    def save_regs fisk = __
      fisk.push(REG_EC)
        .push(REG_CFP)
        .push(REG_SP)
    end

    def restore_regs fisk = __
      fisk.pop(REG_SP)
        .pop(REG_CFP)
        .pop(REG_EC)
    end

    def handle_duparray ary
      write_loc = @temp_stack.push(:object, type: T_ARRAY)

      call_cfunc rb.symbol_address("rb_ary_resurrect"), [__.uimm(ary)]

      __.mov write_loc, __.rax
    end

    class BranchUnless < Struct.new(:pc_dst, :patch_location, :jump_end)
      # The head of the JIT buffer is our jump location
      def patch jit_buf
        pos = jit_buf.pos
        jit_buf.seek(patch_location, IO::SEEK_SET)
        Fisk.new { |__|
          __.jz(__.rel32(pos - jump_end))
        }.write_to(jit_buf)
        jit_buf.seek(pos, IO::SEEK_SET)
      end
    end

    def handle_branchunless dst
      patch_request = BranchUnless.new dst
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      dst = @insn_idx + dst + len
      @insns[dst] = [@insns[dst], patch_request]

      __.test(@temp_stack.pop, __.imm(~Qnil))
        .lazy { |pos| patch_request.patch_location = pos }
        .jz(__.rel32(0xCAFE))
        .lazy { |pos| patch_request.jump_end = pos }
    end

    def handle_opt_minus call_data
      ts = @temp_stack

      exit_addr = exits.make_exit("opt_minus", current_pc, @temp_stack.size)

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

      exit_addr = exits.make_exit("opt_plus", current_pc, @temp_stack.size)

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
          exit_addr ||= exits.make_exit(insn_name, current_pc, @temp_stack.size)

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

      addr = exits.make_exit("setlocal_WC_0", current_pc, @temp_stack.size)

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

    def b fisk
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
  end
end
