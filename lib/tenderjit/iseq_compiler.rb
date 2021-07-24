require "tenderjit/temp_stack"

class TenderJIT
  class ISEQCompiler
    attr_reader :stats

    def initialize stats, jit
      @stats      = stats
      @jit        = jit
      @temp_stack = TempStack.new
    end

    def compile addr
      body  = RbISeqT.new(addr).body
      insns = Fiddle::CArray.unpack(body.iseq_encoded, body.iseq_size, Fiddle::TYPE_VOIDP)

      if body.jit_func.to_i != 0
        puts "already compiled!"
        return
      end

      stats.compiled_methods += 1

      jit_head = jit_buffer.memory + jit_buffer.pos
      cb = CodeBlock.new jit_head

      # ec is in rdi
      # cfp is in rsi

      # Write the prologue for book keeping
      Fisk.new { |_|
        # Write the top exit to the PC.  JIT to JIT calls need to skip
        # this instruction
        _.mov(_.r10, _.imm64(jit_buffer.top_exit))
        _.mov(_.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), _.r10)

        _.mov(_.r10, _.imm64(stats.to_i))
          .inc(_.m64(_.r10, Stats.offsetof("executed_methods")))
          .mov(REG_SP, _.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
      }.write_to(jit_buffer)

      offset = 0
      current_pc = body.iseq_encoded.to_i

      scratch_registers = [
        Fisk::Registers::R9,
        Fisk::Registers::R10,
      ]

      while insn = insns.shift
        name   = rb.insn_name(insn)
        params = insns.shift(rb.insn_len(insn) - 1)

        if respond_to?("handle_#{name}", true)
          fisk = send("handle_#{name}", addr, current_pc, *params)
          fisk.release_all_registers
          fisk.assign_registers(scratch_registers, local: true)
          fisk.write_to(jit_buffer)
        else
          make_exit(name, current_pc, @temp_stack.size).write_to jit_buffer
          break
        end

        current_pc += rb.insn_len(insn) * Fiddle::SIZEOF_VOIDP
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
    end

    private

    def jit_buffer
      @jit.jit_buffer
    end

    def exits; @jit.exit_code; end

    def make_exit exit_insn_name, exit_pc, exit_sp
      jump_addr = exits.make_exit(exit_insn_name, exit_pc, exit_sp)
      Fisk.new { |_|
        _.mov(_.r10, _.imm64(jump_addr))
          .jmp(_.r10)
      }
    end

    CallCompileRequest = Struct.new(:call_info, :patch_loc, :return_loc)
    COMPILE_REQUSTS = []

    def handle_opt_send_without_block iseq_addr, current_pc, call_data
      sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")

      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      # only handle simple methods
      return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      compile_request = CallCompileRequest.new
      compile_request.call_info = ci

      COMPILE_REQUSTS << compile_request

      __ = Fisk.new

      temp_sp = __.register "reg_sp"

      __.put_label(:retry)

      __.lazy { |pos|
        compile_request.patch_loc = pos
      }

      # Flush the SP so that the next Ruby call will push a frame correctly
      __.mov(temp_sp, REG_SP)
        .add(temp_sp, __.imm32(@temp_stack.size * TenderJIT.member_size(RbControlFrameStruct, "sp")))
        .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), temp_sp)

      # Convert the SP to a Ruby integer
      __.shl(temp_sp, __.imm8(1))
        .add(temp_sp, __.imm8(1))

      save_regs __

      __.mov(__.rdi, __.imm64(Fiddle.dlwrap(self)))
        .mov(__.rsi, __.imm64(rb.rb_intern("compile_method")))
        .mov(__.rdx, __.imm64(2))
        .mov(__.rcx, temp_sp)
        .mov(__.r8, __.imm64(Fiddle.dlwrap(compile_request)))
        .mov(__.rax, __.imm64(rb.symbol_address("rb_funcall")))
        .call(__.rax)

      restore_regs __

      __.jmp __.label(:retry)

      __.lazy { |pos| compile_request.return_loc = pos }

      # The method call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)
      __.mov(loc, __.rax)
    end

    def topn stack, i
      Fiddle::Pointer.new(stack - (Fiddle::SIZEOF_VOIDP * (i + 1))).ptr
    end

    def compile_method stack, compile_request
      puts "OMGGG!"
      ci = compile_request.call_info
      mid = ci.vm_ci_mid
      p(ARGC: ci.vm_ci_argc)
      recv = topn(stack, ci.vm_ci_argc)

      current_pos = @jit_buffer.pos
      jump_loc = @jit_buffer.memory + current_pos

      ## Patch the source location to jump here
      __ = Fisk.new
      __.mov(__.r10, __.imm64(jump_loc))
      __.jmp(__.r10)

      @jit_buffer.seek compile_request.patch_loc, IO::SEEK_SET
      __.write_to(@jit_buffer)
      @jit_buffer.seek current_pos

      ## Write out the method call
      __ = Fisk.new
      __.mov(__.rax, __.imm64((42 << 1) | 1))
        .mov(__.r10, __.imm64(@jit_buffer.memory + compile_request.return_loc))
        .jmp(__.r10)

      __.write_to(@jit_buffer)

      # FIXME: this only works on heap allocated objects
      klass = RBasic.new(recv).klass

      cme = RbCallableMethodEntryT.new(rb.rb_callable_method_entry(klass, mid))
      iseq_ptr = RbMethodDefinitionStruct.new(cme.def).body.iseq.iseqptr
      p iseq_ptr
      exit
      p Fiddle.dlunwrap(cme.defined_class)

      iseq  = RbISeqT.new(addr)

      # `vm_call_iseq_setup`
      local_size = iseq.body.local_table_size
      p local_size
      # `vm_call_iseq_setup_normal`

      # `vm_push_frame`
      __ = Fisk.new
      __.sub(REG_CFP, __.imm32(RbControlFrameStruct.size))

      #(ci.vm_ci_argc + 1).times do |i|
      #  p Fiddle.dlunwrap(Fiddle::Pointer.new(stack + (i * 8)).ptr.to_i)
      #end

      #p stack
      #p Fiddle.dlunwrap(Fiddle::Pointer.new(stack).ptr.to_i)
      #p Fiddle.dlunwrap(Fiddle::Pointer.new(stack + 8).ptr.to_i)
      #p Fiddle.dlunwrap(Fiddle::Pointer.new(stack + 16).ptr.to_i)
      puts "OMGOMGOMG"
    end

    def save_regs fisk
      fisk.push(REG_EC)
      fisk.push(REG_CFP)
      fisk.push(REG_SP)
    end

    def restore_regs fisk
      fisk.pop(REG_SP)
      fisk.pop(REG_CFP)
      fisk.pop(REG_EC)
    end

    def handle_opt_lt iseq_addr, current_pc, call_data
      sizeof_sp = member_size(RbControlFrameStruct, "sp")

      ts = @temp_stack

      __ = Fisk.new

      exit_addr = nil

      # Generate runtime checks if we need them
      2.times do |i|
        if ts.peek(i).type != T_FIXNUM
          exit_addr ||= exits.make_exit("opt_lt", current_pc, @temp_stack.size)

          # Is the argument a fixnum?
          __.test(ts.peek(i).loc, __.imm32(rb.c("RUBY_FIXNUM_FLAG")))
            .jz(__.label(:quit!))
        end
      end

      reg_lhs = __.register "lhs"
      reg_rhs = __.register "rhs"
      rhs_loc = ts.pop
      lhs_loc = ts.pop

      # Copy the LHS and RHS in to registers
      __.mov(reg_rhs, rhs_loc)
        .mov(reg_lhs, lhs_loc)

      # Compare them
      __.cmp(reg_lhs, reg_rhs)

      # Conditionally move based on the comparison
      __.mov(reg_lhs, __.imm32(Qtrue))
        .mov(reg_rhs, __.imm32(Qfalse))
        .cmova(reg_lhs, reg_rhs)

      # Push the result on the stack
      __.mov(ts.push(:boolean), reg_lhs)

      # If we needed to generate runtime checks then add the labels and jumps
      if exit_addr
        __.jmp(__.label(:done))

        __.put_label(:quit!)
          .mov(__.rax, __.imm64(exit_addr))
          .jmp(__.rax)

        __.put_label(:done)
      end

      __
    end

    def handle_putobject_INT2FIX_1_ iseq_addr, current_pc
      sizeof_sp = member_size(RbControlFrameStruct, "sp")

      fisk = Fisk.new

      loc = @temp_stack.push(:literal, type: T_FIXNUM)

      fisk.mov loc, fisk.imm32(0x3)

      fisk
    end

    def handle_getlocal_WC_0 iseq_addr, current_pc, idx
      #level = 0
      sizeof_sp = member_size(RbControlFrameStruct, "sp")

      fisk = Fisk.new

      loc = @temp_stack.push(:local)

      __ = fisk

      reg_ep = fisk.register "ep"
      reg_local = fisk.register "local"

      # Get the local value from the EP
      __.mov(reg_ep, __.m64(REG_CFP, RbControlFrameStruct.offsetof("ep")))
        .sub(reg_ep, __.imm8(Fiddle::SIZEOF_VOIDP * idx))
        .mov(reg_local, __.m64(reg_ep))
        .mov(loc, reg_local)
    end

    def handle_putself iseq_addr, current_pc
      loc = @temp_stack.push(:self)

      fisk = Fisk.new
      __ = fisk
      reg_self = fisk.register "self"

      # Get self from the CFP
      __.mov(reg_self, __.m64(REG_CFP, RbControlFrameStruct.offsetof("self")))
        .mov(loc, reg_self)
    end

    def handle_putobject iseq_addr, current_pc, literal
      fisk = Fisk.new

      loc = if rb.RB_FIXNUM_P(literal)
              @temp_stack.push(:literal, type: T_FIXNUM)
            else
              @temp_stack.push(:literal)
            end

      reg = fisk.register
      fisk.mov reg, fisk.imm64(literal)
      fisk.mov loc, reg
    end

    # `leave` instruction
    def handle_leave iseq_addr, current_pc
      sizeof_sp = member_size(RbControlFrameStruct, "sp")

      loc = @temp_stack.pop

      # FIXME: We need to check interrupts and exit
      fisk = Fisk.new

      jump_reg = fisk.register "jump to exit"

      __ = fisk
      # Copy top value from the stack in to rax
      __.mov __.rax, loc

      # Read the jump address from the PC
      __.mov jump_reg, __.m64(REG_CFP, RbControlFrameStruct.offsetof("pc"))
      __.jmp jump_reg

      fisk
    end

    def rb; Internals; end

    def member_size struct, member
      TenderJIT.member_size(struct, member)
    end
  end
end
