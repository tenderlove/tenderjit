# frozen_string_literal: true

require "tenderjit/temp_stack"
require "tenderjit/runtime"
require "tenderjit/jit_context"
require "tenderjit/iseq_compiler/frames"

class TenderJIT
  class ISEQCompiler
    LJUST = 22
    JMP_BYTES = 5

    SCRATCH_REGISTERS = [
      Fisk::Registers::R9,
      Fisk::Registers::R10,
      Fisk::Registers::R11,
    ]

    attr_reader :blocks

    def initialize jit, addr
      @iseq_path = Fiddle.dlunwrap CFuncs.rb_iseq_path(addr)
      @iseq_label = Fiddle.dlunwrap CFuncs.rb_iseq_label(addr)

      if $DEBUG
        puts "New ISEQ Compiler: <#{sprintf("%#x", addr)} #{@iseq_path}:#{@iseq_label}>"
        size = 1048576
        memory        = Fisk::Helpers.mmap_jit(size)
        @string_buffer = Fisk::Helpers::JITBuffer.new(memory, size)
      end

      @jit        = jit
      @temp_stack = TempStack.new
      @iseq       = addr
      @body       = RbISeqT.body(addr).to_i

      @insns      = Fiddle::CArray.unpack(Fiddle::Pointer.new(RbIseqConstantBody.iseq_encoded(@body)),
                                          RbIseqConstantBody.iseq_size(@body),
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

    def compile
      if $DEBUG
        puts "Compiling iseq addr: #{sprintf("%#x", @iseq)}"
      end

      if RbIseqConstantBody.jit_func(@body) != 0
        return RbIseqConstantBody.jit_func(@body)
      end

      stats.compiled_methods += 1

      jit_head = jit_buffer.address

      # ec is in rdi
      # cfp is in rsi

      @jit.interpreter_call.each_byte { |byte| jit_buffer.putc byte }

      @skip_bytes = @jit.interpreter_call.bytesize

      # Write the prologue for book keeping
      Fisk.new { |_|
        _.mov(_.r10, _.uimm(stats.to_i))
          .inc(_.m64(_.r10, Stats.offsetof("executed_methods")))
          .mov(REG_BP, _.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
          #.int(_.lit(3))
      }.write_to(jit_buffer)

      resume_compiling(0, TempStack.new)

      if $DEBUG
        $stderr.puts "NEW ENTRY HEAD #{sprintf("%#x", jit_head.to_i)}"
      end
      RbIseqConstantBody.set_jit_func(@body, jit_head)

      jit_head
    end

    private

    class Block
      attr_reader :entry_idx, :jit_position, :start_address
      attr_accessor :end_address

      def initialize entry_idx, jit_position, start_address
        @entry_idx     = entry_idx
        @jit_position  = jit_position
        @start_address = start_address
        @end_address   = end_address
      end

      def done?; @end_address; end
    end

    def resume_compiling insn_idx, temp_stack
      @temp_stack = temp_stack
      @insn_idx   = insn_idx
      @blocks << Block.new(@insn_idx, jit_buffer.pos, jit_buffer.address)
      enc = RbIseqConstantBody.iseq_encoded(@body)
      @current_pc = enc.to_i + (insn_idx * Fiddle::SIZEOF_VOIDP)

      while(insn = @insns[@insn_idx])
        name   = rb.insn_name(insn)
        len    = rb.insn_len(insn)
        params = @insns[@insn_idx + 1, len - 1]

        if $DEBUG
          puts "#{sprintf("%04d", @insn_idx)} compiling #{name.ljust(LJUST)} #{sprintf("%#x", @iseq.to_i)} SP #{@temp_stack.size}"
        end
        if respond_to?("handle_#{name}", true)
          if $DEBUG
            print_str("#{sprintf("%04d", @insn_idx)} running   #{name.ljust(LJUST)} #{sprintf("%#x", @iseq.to_i)} SP #{@temp_stack.size}\n")
          end
          @fisk = Fisk.new
          # Uncomment for finding GC related bugs
          #GC.start
          v = send("handle_#{name}", *params)
          if v == :quit
            make_exit(name, @current_pc, @temp_stack).write_to jit_buffer
            break
          end
          @fisk.release_all_registers
          @fisk.assign_registers(SCRATCH_REGISTERS, local: true)
          @fisk.write_to(jit_buffer)
          if v == :stop
            break
          end

          if v == :continue
            @blocks.last.end_address = jit_buffer.address
            @blocks << Block.new(@insn_idx + len, jit_buffer.pos, jit_buffer.address)
          end
        else
          if $DEBUG
            puts "#{@insn_idx} COULDN'T COMPILE #{name.ljust(LJUST)} #{sprintf("%#x", @iseq.to_i)}"
          end
          make_exit(name, @current_pc, @temp_stack).write_to jit_buffer
          break
        end

        @insn_idx += len
        @current_pc += len * Fiddle::SIZEOF_VOIDP
      end

      @blocks.last.end_address = jit_buffer.address
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
      jump_addr = exits.make_exit(exit_insn_name, exit_pc, temp_stack.size)
      Fisk.new { |_|
        _.mov(_.r10, _.uimm(jump_addr))
          .jmp(_.r10)
      }
    end

    IVarRequest = Struct.new(:id, :current_pc, :next_pc, :temp_stack, :deferred_entry)

    def iv_index_for recv, id
      klass        = CFuncs.rb_obj_class(recv)
      iv_index_tbl = RbClassExt.iv_index_tbl(class_ext(klass)).to_i
      value        = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)

      if iv_index_tbl == 0 || 0 == CFuncs.rb_st_lookup(iv_index_tbl, id, value.ref)
        CFuncs.rb_ivar_set(recv, id, Qundef)
        iv_index_tbl = RbClassExt.iv_index_tbl(class_ext(klass)).to_i
        CFuncs.rb_st_lookup(iv_index_tbl, id, value.ref)
      end

      RbIvIndexTblEntry.new(value).index
    end

    def compile_getinstancevariable cfp, req, loc
      recv = RbControlFrameStruct.self(cfp)

      if rb.RB_SPECIAL_CONST_P(recv)
        raise NotImplementedError, "no ivar reads on non-heap objects"
      end

      type = rb.RB_BUILTIN_TYPE(recv)
      if type != T_OBJECT
        raise NotImplementedError, "no ivar reads on non objects #{type}"
      end

      ivar_idx = iv_index_for recv, req.id

      code_start = jit_buffer.address
      patch_at   = loc - jit_buffer.memory.to_i
      return_loc = patch_at + JMP_BYTES

      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

        temp = rt.temp_var
        temp.write cfp_ptr.self

        self_ptr = rt.pointer(temp, type: RObject)

        # If the object class is the same, continue
        rt.if_eq(self_ptr.basic.klass, RBasic.klass(recv).to_i) {

          # If it's an embedded object, read the ivar out of the object
          rt.test_flags(self_ptr.basic.flags, ROBJECT_EMBED) {
            rt.return_value = self_ptr.as.ary[ivar_idx]

          }.else { # Otherwise, check the extended table
            temp.write self_ptr.as.heap.ivptr
            rt.return_value = rt.pointer(temp)[ivar_idx]
          }

        }.else { # Otherwise we need to recompile
          rt.patchable_jump req.deferred_entry
        }

        temp.release!

        rt.jump jit_buffer.memory.to_i + return_loc
      end

      patch_source_jump jit_buffer, at: patch_at, to: code_start

      code_start
    end

    def handle_putstring str
      addr = Fiddle::Handle::DEFAULT["rb_ec_str_resurrect"]
      with_runtime do |rt|
        rt.call_cfunc addr, [REG_EC, str]
        rt.push rt.return_value, name: :string
      end
    end

    class CompileSend < Struct.new(:call_info, :temp_stack, :current_pc, :next_pc, :blockiseq, :deferred_entry)
      def make_exit exits, name = "send"
        exits.make_exit(name, current_pc, temp_stack.size)
      end

      def has_blockiseq?
        blockiseq != 0
      end

      def has_block?
        has_blockiseq? || has_blockarg?
      end

      def has_blockarg?
        call_info.vm_ci_flag & VM_CALL_ARGS_BLOCKARG == VM_CALL_ARGS_BLOCKARG
      end
    end

    class CompileSendWithoutBlock < CompileSend
      def initialize call_info, temp_stack, current_pc, next_pc
        super(call_info, temp_stack, current_pc, next_pc, 0)
      end

      def make_exit exits, name = "opt_send_without_block"
        exits.make_exit(name, current_pc, temp_stack.size)
      end

      def has_block?; false; end
    end


    def compile_opt_send_without_block cfp, req, loc
      compile_send cfp, req, loc
    end

    def handle_send call_data, blockiseq
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      req = CompileSend.new(ci, @temp_stack.dup.freeze, current_pc, next_pc, blockiseq)

      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_send, [REG_CFP, req, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      req.deferred_entry = deferred.entry.to_i
      deferred.call

      if req.has_blockarg?
        # blockargs aren't counted in argc, so we need to pop them manually
        # IOW argc for `foo(&:x)` will be 0, but :x will be on the stack
        @temp_stack.pop
      end

      (ci.vm_ci_argc + 1).times { @temp_stack.pop }

      # The method call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)

      # Jump in to the deferred compiler
      with_runtime do |rt|
        rt.patchable_jump req.deferred_entry
        rt.pop_reg REG_BP
        rt.write loc, rt.return_value
      end
    end

    class CompileBlock < Struct.new(:call_info, :temp_stack, :current_pc, :next_pc, :deferred_entry)
      def make_exit exits, name = "invokeblock"
        exits.make_exit(name, current_pc, temp_stack.size)
      end
    end

    def compile_invokeblock_no_handler cfp, req, loc
      side_exit = req.make_exit(exits)

      method_entry_addr = jit_buffer.address

      with_runtime do |rt|
        rt.flush_pc_and_sp req.next_pc, REG_BP
        # TODO: We need an overflow check here, I think
        #rt.check_vm_stack_overflow req.temp_stack, overflow_exit, local_size - param_size, iseq.body.stack_max
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

        temp = rt.temp_var
        temp.write cfp_ptr.ep
        ep_ptr = rt.pointer(temp)

        # Find the LEP (or "Local" EP)
        rt.test_flags(ep_ptr[VM_ENV_DATA_INDEX_FLAGS], VM_ENV_FLAG_LOCAL).else {
          # TODO: need a test for this case
          rt.break
        }

        # Get the block handler
        temp.write ep_ptr[VM_ENV_DATA_INDEX_SPECVAL]
        rt.if_eq(temp, VM_BLOCK_HANDLER_NONE) {
          rt.jump side_exit
        }.else {
          rt.patchable_jump req.deferred_entry
        }
        temp.release!
      end

      method_entry_addr
    end

    def compile_invokeblock_iseq_handler iseq_ptr, captured, return_loc, req, temp_stack
      ci = req.call_info

      unless ci.supported_call?
        # TODO: can this happen?
        raise NotImplementedError
      end

      iseq = RbISeqT.new iseq_ptr
      param_size = iseq.body.param.size
      local_size = iseq.body.local_table_size
      opt_pc     = 0 # we don't handle optional parameters rn

      method_entry_addr = jit_buffer.address

      with_runtime(temp_stack) do |rt|
        if temp_stack.empty?
          rt.flush_pc_and_sp req.next_pc, REG_BP
        else
          rt.flush_pc_and_sp req.next_pc, temp_stack.first.loc
        end

        # TODO: We need an overflow check here, I think
        #rt.check_vm_stack_overflow req.temp_stack, overflow_exit, local_size - param_size, iseq.body.stack_max
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

        temp = rt.temp_var
        temp.write cfp_ptr.ep
        ep_ptr = rt.pointer(temp)

        # Find the LEP (or "Local" EP)
        rt.test_flags(ep_ptr[VM_ENV_DATA_INDEX_FLAGS], VM_ENV_FLAG_LOCAL).else {
          # TODO: need a test for this case
          rt.break
        }

        # Get the block handler
        temp.write ep_ptr[VM_ENV_DATA_INDEX_SPECVAL]

        rt.temp_var do |check|
          check.write temp.to_register
          check.and 0x3
          # Check if it's an ISEQ
          rt.if_eq(check.to_register, 0x1) {
            # Convert it to a captured block
            temp.and(~0x3)
          }.else {
            rt.patchable_jump req.deferred_entry
          }
        end

        # Dereference the captured block
        captured_ptr = rt.pointer(temp, type: rb.struct("rb_captured_block"))
        temp.write captured_ptr.self

        ts = temp_stack.dup

        Frames::Block.new(
          iseq_ptr,
          temp,
          SpecVals::PreviousEP.new(captured.ep),
          0,
          iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
          local_size - param_size, ts).push(rt)

        # Save the base pointer
        rt.push_reg REG_BP

        ret_loc = jit_buffer.memory.to_i + return_loc
        var = rt.temp_var
        var.write ret_loc

        # Callee will `ret` to return which will pop this address from the
        # stack and jump to it
        rt.push_reg var

        # If the iseq hasn't been compiled yet, put in a stub that will compile
        # it and jump back.
        if iseq.body.jit_func == 0
          comp_req = CompileISeqBlock.new(iseq_ptr, temp_stack.dup.freeze)
          @compile_requests << Fiddle::Pinned.new(comp_req)

          deferred = @jit.deferred_call(NoFlush.new) do |ctx|
            ctx.with_runtime do |rt|
              rt.rb_funcall self, :compile_iseq, [REG_CFP, comp_req, rt.return_value]

              rt.NUM2INT(rt.return_value)

              rt.jump rt.return_value
            end
          end

          deferred.call

          rt.patchable_jump deferred.entry
        end

        # Dereference the JIT function address, skipping the REG_* assigments
        # and jump to it
        var.write iseq.body.to_i
        iseq_body = rt.pointer(var, type: RbIseqConstantBody)
        var.write iseq_body.jit_func
        rt.add var, @skip_bytes

        rt.jump var

        var.release!
      end

      method_entry_addr
    end

    class NoFlush
      def flush x; end
    end

    def compile_invokeblock cfp, req, loc
      ep = rb.VM_EP_LEP(RbControlFrameStruct.ep(cfp))
      bh = rb.VM_ENV_BLOCK_HANDLER(ep)

      patch_loc = loc - jit_buffer.memory.to_i
      return_loc = patch_loc + JMP_BYTES

      if bh == VM_BLOCK_HANDLER_NONE
        return compile_invokeblock_no_handler cfp, req, loc
      end

      if rb.VM_BH_ISEQ_BLOCK_P(bh)
        captured_block = rb.VM_BH_TO_ISEQ_BLOCK(bh)
        captured = rb.struct("rb_captured_block").new(captured_block)
        iseq_ptr = captured.code.iseq
        @jit.compile_iseq_t iseq_ptr

        method_entry_addr = compile_invokeblock_iseq_handler iseq_ptr, captured, return_loc, req, req.temp_stack
        patch_source_jump jit_buffer, at: patch_loc, to: method_entry_addr
        method_entry_addr
      else
        raise NotImplementedError
        # TODO: need to implement vm_block_handler_type
      end
    end

    def handle_invokeblock call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      req = CompileBlock.new(ci, @temp_stack.dup.freeze, current_pc, next_pc)
      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_invokeblock, [REG_CFP, req, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      req.deferred_entry = deferred.entry.to_i
      deferred.call

      # The method call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)

      # Jump in to the deferred compiler
      with_runtime do |rt|
        rt.patchable_jump req.deferred_entry
        rt.pop_reg REG_BP
        rt.write loc, rt.return_value
      end
    end

    def compile_iseq cfp, req, loc
      @jit.compile_iseq_t req.iseq_ptr

      patch_loc = loc - jit_buffer.memory.to_i
      patch_source_jump jit_buffer, at: patch_loc, to: loc + JMP_BYTES
      loc + JMP_BYTES
    end

    def handle_getglobal gid
      addr = Fiddle::Handle::DEFAULT["rb_gvar_get"]
      with_runtime do |rt|
        rt.call_cfunc addr, [gid]
        rt.push rt.return_value, name: :unknown
      end
    end

    def handle_setglobal gid
      global_name = Fiddle.dlunwrap(CFuncs.rb_id2str(gid))
      stack_val   = @temp_stack.first.type
      addr = Fiddle::Handle::DEFAULT["rb_gvar_set"]

      with_runtime do |rt|
        if global_name == "$halt_at_runtime" && stack_val == true
          rt.break
        else
          # GC could be triggered
          rt.flush_sp
          loc = @temp_stack.pop

          rt.call_cfunc addr, [gid, loc]
        end
      end
    end

    def handle_dup
      handle_topn 0
    end

    def handle_concatstrings num
      loc = @temp_stack[num - 1]
      addr = Fiddle::Handle::DEFAULT["rb_str_concat_literals"]
      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp

        num.times { @temp_stack.pop }
        rt.with_ref(loc) do |reg|
          rt.call_cfunc addr, [num, reg]
        end
        rt.push rt.return_value, name: __method__, type: :string
      end
    end

    def compile_setinstancevariable cfp, req, loc
      recv = RbControlFrameStruct.self(cfp)

      if rb.RB_SPECIAL_CONST_P(recv)
        raise NotImplementedError, "no ivar reads on non-heap objects"
      end

      type = rb.RB_BUILTIN_TYPE(recv)
      if type != T_OBJECT
        raise NotImplementedError, "no ivar reads on non objects #{type}"
      end

      klass        = CFuncs.rb_obj_class(recv).to_i
      iv_index_tbl = RbClassExt.iv_index_tbl(class_ext(klass)).to_i

      value        = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)

      if iv_index_tbl == 0 || 0 == CFuncs.rb_st_lookup(iv_index_tbl, req.id, value.ref)
        CFuncs.rb_ivar_set(recv, req.id, Qundef)
        iv_index_tbl = RbClassExt.iv_index_tbl(class_ext(klass)).to_i
        value        = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
        CFuncs.rb_st_lookup(Fiddle::Pointer.new(iv_index_tbl.to_i), req.id, value.ref)
      end

      ivar_idx = value.ptr.to_int

      code_start = jit_buffer.address
      return_loc = patch_source_jump jit_buffer, at: (loc - jit_buffer.memory.to_i),
                                                 to: code_start

      temp_stack = req.temp_stack.dup
      read_loc = temp_stack.pop

      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

        temp = rt.temp_var
        temp.write cfp_ptr.self

        self_ptr = rt.pointer(temp, type: RObject)

        # If the object class is the same, continue
        rt.if_eq(self_ptr.basic.klass, RBasic.klass(recv).to_i) {

          # If it's an embedded object, write to the embedded array
          rt.test_flags(self_ptr.basic.flags, ROBJECT_EMBED) {
            self_ptr.as.ary[ivar_idx] = read_loc

          }.else { # Otherwise, the extended table
            temp.write self_ptr.as.heap.ivptr
            rt.pointer(temp)[ivar_idx] = read_loc
          }

        }.else { # Otherwise we need to recompile
          rt.patchable_jump req.deferred_entry
        }

        temp.release!

        rt.jump jit_buffer.memory.to_i + return_loc
      end

      code_start
    end

    def handle_setinstancevariable id, ic
      req = IVarRequest.new(id, current_pc, next_pc, @temp_stack.dup.freeze)

      @compile_requests << Fiddle::Pinned.new(req)

      # `deferred_call` preserves the stack, so we can't pop from the temp
      # stack until after this method call
      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_setinstancevariable, [REG_CFP, req, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      # jump back to the re-written jmp
      deferred.call

      @temp_stack.pop

      req.deferred_entry = deferred.entry.to_i

      with_runtime do |rt|
        rt.patchable_jump req.deferred_entry
      end
    end

    def handle_checktype type
      loc = @temp_stack.pop

      if HEAP_TYPES.include?(type)
        write_loc = @temp_stack.push :boolean

        with_runtime do |rt|
          # If the type is a heap allocated type, then if the stack object
          # is a "special const", it can't be what we want
          rt.if(rt.RB_SPECIAL_CONST_P(loc)) {
            rt.write write_loc, Qfalse
          }.else {
            rt.if_eq(rt.RB_BUILTIN_TYPE(loc), type) {
              rt.write write_loc, Qtrue
            }.else {
              rt.write write_loc, Qfalse
            }
          }
        end
      else
        raise NotImplementedError
      end
    end

    def handle_getinstancevariable id, ic
      req = IVarRequest.new(id, current_pc, next_pc, @temp_stack.dup.freeze)

      exit_addr = exits.make_exit("temporary_exit", current_pc, @temp_stack.size)

      write_loc = @temp_stack.push(:unknown)

      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          temp = rt.temp_var
          temp.write rt.pointer(rt.return_value)[0]
          temp.shl   24
          temp.shr   32
          rt.add     temp, 5
          rt.add     temp, rt.return_value

          rt.if_eq(temp.to_register, deferred.entry.to_i) {
            temp.write 0xFFFFFF_00000000_FF
            temp.and rt.pointer(rt.return_value)[0]
            rt.pointer(rt.return_value)[0] = temp
            temp.write exit_addr
            temp.sub rt.return_value
            rt.sub temp.to_register, 5
            temp.shl 8
            temp.or rt.pointer(rt.return_value)[0]
            rt.pointer(rt.return_value)[0] = temp
            temp.release!

            rt.rb_funcall self, :compile_getinstancevariable, [REG_CFP, req, rt.return_value]

            rt.NUM2INT(rt.return_value)

            rt.jump rt.return_value
          }.else {
            rt.break
            rt.jump exit_addr
          }
        end
      end

      # jump back to the re-written jmp
      deferred.call

      req.deferred_entry = deferred.entry.to_i

      with_runtime do |rt|
        rt.patchable_jump req.deferred_entry
        rt.write write_loc, rt.return_value
      end
    end

    def compile_opt_aref cfp, req, patch_loc
      stack = RbControlFrameStruct.sp(cfp)

      ci = req.call_info
      peek_recv = topn(stack, ci.vm_ci_argc).to_i

      if rb.RB_SPECIAL_CONST_P(peek_recv)
        return compile_send cfp, req, patch_loc
      end

      ## Compile the target method
      klass = RBasic.new(peek_recv).klass

      entry_location = jit_buffer.address

      loc = patch_loc - jit_buffer.memory.to_i

      param = req.temp_stack[0] # param
      recv  = req.temp_stack[1] # recv

      with_runtime do |rt|
        rt.temp_var do |tmp|
          tmp.write recv
          _self = rt.pointer(tmp, type: RObject)

          rt.if_eq(_self.basic.klass, klass) {
            klass = Fiddle.dlunwrap(klass)

            # GC can be triggered
            rt.flush_pc_and_sp req.next_pc, req.temp_stack.first.loc

            rt.push_reg REG_BP # Callee will pop this

            # We know it's an array at compile time
            if klass == ::Array
              rt.call_cfunc symbol_addr("rb_ary_aref1"), [recv, param], auto_align: false, preserve_tempvars: false

              # We know it's a hash at compile time
            elsif klass == ::Hash
              rt.call_cfunc symbol_addr("rb_hash_aref"), [recv, param], auto_align: false, preserve_tempvars: false

            else
              compile_send cfp, req, patch_loc
            end
          }.else {
            rt.patchable_jump req.deferred_entry
          }
        end

        # patched a jmp and it is 5 bytes
        rt.jump jit_buffer.memory.to_i + loc + 5
      end

      jit_buffer.patch_jump at: loc, to: entry_location

      entry_location
    end

    def compile_opt_aset cfp, req, patch_loc
      stack = RbControlFrameStruct.sp(cfp)

      ci = req.call_info
      peek_recv = topn(stack, ci.vm_ci_argc).to_i

      if rb.RB_SPECIAL_CONST_P(peek_recv)
        raise NotImplementedError, "no aset on non-heap objects"
      end

      ## Compile the target method
      klass = RBasic.new(peek_recv).klass # FIXME: this only works on heap allocated objects

      entry_location = jit_buffer.address

      patch_loc = patch_loc - jit_buffer.memory.to_i

      jit_buffer.patch_jump at: patch_loc, to: entry_location

      param2 = req.temp_stack.peek(0).loc # param
      param1 = req.temp_stack.peek(1).loc # param
      recv   = req.temp_stack.peek(2).loc # recv

      with_runtime do |rt|
        temp = rt.temp_var
        temp.write recv

        _self = rt.pointer(temp, type: RObject)

        rt.if_eq(_self.basic.klass, RBasic.klass(peek_recv).to_i) {
          klass = Fiddle.dlunwrap(klass)

          # GC can be triggered
          rt.flush_pc_and_sp req.next_pc, req.temp_stack.first.loc

          # We know it's an array at compile time
          if klass == ::Array
            rt.temp_var do |x|
              x.write param1
              rt.FIX2LONG(x)
              rt.call_cfunc(symbol_addr("rb_ary_store"), [recv, x, param2])
            end
            rt.return_value = param2

            # We know it's a hash at compile time
          elsif klass == ::Hash
            rt.call_cfunc(symbol_addr("rb_hash_aset"), [recv, param1, param2])
            rt.return_value = param2

          else
            raise NotImplementedError
          end
        }.else {
          rt.break
          rt.patchable_jump req.deferred_entry
        }
        temp.release!

        # patched a jmp and it is 5 bytes
        rt.jump jit_buffer.memory.to_i + patch_loc + 5
      end

      entry_location
    end

    class CompileOptAref < Struct.new(:call_info, :temp_stack, :current_pc, :next_pc, :deferred_entry)
      def has_block?; false; end
      def has_blockarg?; false; end

      def make_exit exits, name = "opt_aref"
        exits.make_exit(name, current_pc, temp_stack.size)
      end
    end

    def handle_opt_aref call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      argc = ci.vm_ci_argc
      return :quit unless argc == 1

      # only handle simple methods
      #return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      req = CompileOptAref.new
      req.call_info = ci
      req.temp_stack = @temp_stack.dup.freeze
      req.current_pc = current_pc
      req.next_pc = next_pc

      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_opt_aref, [REG_CFP, req, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      req.deferred_entry = deferred.entry.to_i

      (argc + 1).times { @temp_stack.pop }

      #Jump in to the deferred compiler
      with_runtime do |rt|
        rt.patchable_jump req.deferred_entry

        # The call will return here, and its return value will be in RAX
        loc = @temp_stack.push(:unknown)
        rt.pop_reg(REG_BP)
        rt.write(loc, rt.return_value)
      end
    end

    def handle_opt_send_without_block call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      exit_addr = exits.make_exit("temporary_exit", current_pc, @temp_stack.size)

      # only handle simple methods
      #return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      compile_request = CompileSendWithoutBlock.new(ci, @temp_stack.dup.freeze, current_pc, next_pc)

      @compile_requests << Fiddle::Pinned.new(compile_request)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          temp = rt.temp_var
          temp.write rt.pointer(rt.return_value)[0]
          temp.shl   24
          temp.shr   32
          rt.add     temp, 5
          rt.add     temp, rt.return_value

          rt.if_eq(temp.to_register, deferred.entry.to_i) {
            temp.write 0xFFFFFF_00000000_FF
            temp.and rt.pointer(rt.return_value)[0]
            rt.pointer(rt.return_value)[0] = temp
            temp.write exit_addr
            temp.sub rt.return_value
            rt.sub temp.to_register, 5
            temp.shl 8
            temp.or rt.pointer(rt.return_value)[0]
            rt.pointer(rt.return_value)[0] = temp
            temp.release!

            rt.rb_funcall self, :compile_opt_send_without_block, [REG_CFP, compile_request, rt.return_value]

            rt.NUM2INT(rt.return_value)

            rt.jump rt.return_value
          }.else {
            rt.break
            rt.jump exit_addr
          }
        end
      end

      compile_request.deferred_entry = deferred.entry

      deferred.call

      (ci.vm_ci_argc + 1).times { @temp_stack.pop }

      with_runtime do |rt|
        # Jump in to the deferred compiler
        rt.patchable_jump compile_request.deferred_entry

        # The method call will return here, and its return value will be in RAX
        loc = @temp_stack.push(:unknown)
        rt.pop_reg REG_BP
        rt.write loc, rt.return_value
      end
    end

    def topn stack, i
      Fiddle::Pointer.new(stack - (Fiddle::SIZEOF_VOIDP * (i + 1))).ptr.to_i
    end

    def compile_jump cfp, req, patch_loc
      target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }

      unless target_block
        resume_compiling req.jump_idx, req.temp_stack.dup
        target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }
      end

      patch_loc = patch_loc - jit_buffer.memory.to_i

      jit_buffer.patch_jump at: patch_loc,
                            to: target_block.start_address,
                            type: req.jump_type

      @compile_requests.delete_if { |x| x.ref == req }

      target_block.start_address
    end

    def patch_source_jump jit_buffer, at:, to: jit_buffer.address
      ## Patch the source location to jump here
      pos = jit_buffer.pos
      jit_buffer.write_jump at: at, to: to
      return_loc = jit_buffer.pos
      jit_buffer.seek pos, IO::SEEK_SET
      return_loc
    end

    def compile_call_iseq iseq, req, argc, iseq_ptr, recv, cme, temp_stack, return_loc
      # `vm_call_iseq_setup`
      param_size = iseq.body.param.size
      local_size = iseq.body.local_table_size
      opt_pc     = 0 # we don't handle optional parameters rn

      # `vm_call_iseq_setup_2` FIXME: we need to deal with TAILCALL
      # `vm_call_iseq_setup_normal` FIXME: we need to deal with TAILCALL

      # pop locals and recv off the stack
      #(ci.vm_ci_argc + 1).times { @temp_stack.pop }

      overflow_exit = req.make_exit(exits)

      recv_loc = temp_stack.peek(argc).loc

      # Write next PC to CFP
      # Pop params and self from the stack
      with_runtime do |rt|
        rt.flush_pc_and_sp req.next_pc, recv_loc
        rt.check_vm_stack_overflow req.temp_stack, overflow_exit, local_size - param_size, iseq.body.stack_max

        ts = temp_stack.dup

        if req.has_block?
          Frames::ISeq.new(
            iseq_ptr,
            recv_loc,
            SpecVals::CapturedBlock.new(rb, req.blockiseq),
            cme,
            iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
            local_size - param_size, ts).push(rt)
        else
          # `vm_push_frame`
          Frames::ISeq.new(
            iseq_ptr,
            recv_loc,
            SpecVals::NULL,
            cme,
            iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
            local_size - param_size, ts).push rt
        end
      end

      with_runtime do |rt|
        # Save the base pointer
        rt.push_reg REG_BP

        ret_loc = jit_buffer.memory.to_i + return_loc
        var = rt.temp_var
        var.write ret_loc

        # Callee will `ret` to return which will pop this address from the
        # stack and jump to it
        rt.push_reg var

        # Dereference the JIT function address, skipping the REG_* assigments
        # and jump to it
        if $DEBUG
          $stderr.puts "Should return to #{sprintf("%#x", ret_loc)}"
        end
        var.write iseq.body.to_i
        iseq_body = rt.pointer(var, type: RbIseqConstantBody)
        var.write iseq_body.jit_func
        rt.add var, @skip_bytes

        rt.jump var

        var.release!
      end
    end

    def compile_call_cfunc iseq, req, argc, iseq_ptr, recv, cme, return_loc
      cfunc = RbMethodDefinitionStruct.new(cme.def).body.cfunc

      temp_stack = req.temp_stack

      overflow_exit = req.make_exit(exits)

      ## Pop params and self from the stack
      with_runtime do |rt|
        rt.flush_pc_and_sp req.next_pc, temp_stack[argc]

        rt.check_vm_stack_overflow temp_stack, overflow_exit, 0, 0
      end

      recv_loc = temp_stack.peek(argc).loc
      ts = temp_stack.dup

      with_runtime do |rt|
        if req.has_block?
          Frames::CFunc.new(temp_stack.peek(argc).loc,
                            SpecVals::CapturedBlock.new(rb, req.blockiseq),
                            cme,
                            ts).push(rt)
        else
          Frames::CFunc.new(temp_stack.peek(argc).loc,
                            SpecVals::NULL,
                            cme,
                            ts).push(rt)
        end

        rt.with_ref(temp_stack[argc - 1]) do |sp|
          rt.call_cfunc cfunc.invoker.to_i, [recv_loc, argc, sp, cfunc.func.to_i]
        end

        ec_ptr = rt.pointer REG_EC, type: RbExecutionContextT
        cfp_ptr = rt.pointer REG_CFP, type: RbControlFrameStruct

        # Pop the frame then assign it to the ec
        cfp_ptr.add
        ec_ptr.cfp = cfp_ptr

        rt.push_reg REG_BP # Caller expects to pop REG_BP

        rt.jump jit_buffer.memory.to_i + return_loc
      end
    end

    def handle_anytostring
      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp
        rt.call_cfunc Fiddle::Handle::DEFAULT["rb_obj_as_string_result"],
          [@temp_stack.pop, @temp_stack.pop]
        rt.write @temp_stack.push(:string), rt.return_value
      end
    end

    def handle_objtostring cd
      handle_opt_send_without_block cd
    end

    class CompileISeqBlock < Struct.new(:iseq_ptr, :temp_stack)
    end

    def compile_call_ivar cfp, iseq, req, argc, iseq_ptr, recv, cme, return_loc
      raise NotImplementedError if argc > 0

      ivar_id = RbMethodDefinitionStruct.new(cme.def).body.attr.id
      ivar_idx = iv_index_for recv, ivar_id

      with_runtime do |rt|
        # caller expects to pop REG_BP, so we need this for alignment
        rt.push_reg REG_BP
        recv_loc = req.temp_stack.peek(argc).loc

        rt.temp_var do |temp|
          temp.write recv_loc

          self_ptr = rt.pointer(temp, type: RObject)

          # If it's an embedded object, read the ivar out of the object
          rt.test_flags(self_ptr.basic.flags, ROBJECT_EMBED) {
            rt.return_value = self_ptr.as.ary[ivar_idx]

          }.else { # Otherwise, check the extended table
            temp.write self_ptr.as.heap.ivptr
            rt.return_value = rt.pointer(temp)[ivar_idx]
          }
        end

        rt.jump jit_buffer.memory.to_i + return_loc
      end
    end

    class SendCI < Struct.new(:vm_ci_mid, :vm_ci_argc, :old_ci)
      def vm_ci_flag; old_ci.vm_ci_flag; end

      def splat?
        old_ci.splat?
      end

      def supported_call?
        old_ci.supported_call?
      end
    end

    def compile_call_optimized cfp, iseq, req, argc, iseq_ptr, recv, cme, ci, return_loc
      case optimized_method_type(cme.def)
      when rb.c("OPTIMIZED_METHOD_TYPE_SEND")
        stack = RbControlFrameStruct.sp(cfp)
        method_name = topn(stack, argc - 1)

        method_id = CFuncs.rb_sym2id(method_name)
        new_ci = SendCI.new(method_id, argc - 1, ci)

        ts = req.temp_stack.dup
        params = (argc - 1).times.map { ts.pop_item }.reverse
        with_runtime do |rt|
          sym_loc = ts.pop
          params.each do |param|
            rt.write sym_loc, param.loc
            sym_loc = param.loc
            ts.push(param.name, type: param.type)
          end

          new_req = CompileSend.new(new_ci, ts.freeze, req.current_pc, req.next_pc, req.blockiseq)
          @compile_requests << Fiddle::Pinned.new(new_req)

          deferred = @jit.deferred_call(ts) do |ctx|
            ctx.with_runtime do |rt|
              rt.rb_funcall self, :compile_send, [REG_CFP, new_req, rt.return_value]

              rt.NUM2INT(rt.return_value)

              rt.jump rt.return_value
            end
          end

          new_req.deferred_entry = deferred.entry.to_i
          deferred.call

          rt.patchable_jump new_req.deferred_entry
          rt.jump jit_buffer.memory.to_i + return_loc
        end
      when rb.c("OPTIMIZED_METHOD_TYPE_CALL")
        # https://github.com/ruby/ruby/blob/cbf2078a25c3efb12f45b643a636ff7bb4d402b6/vm_eval.c#L270
        with_runtime do |rt|
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          func_addr = Fiddle::Handle::DEFAULT["rb_vm_invoke_proc"]
          recv_loc = req.temp_stack.peek(argc).loc

          if req.has_block?
            cfp_ptr.block_code = req.blockiseq
          end

          rt.push_reg REG_BP # Caller expects to pop REG_BP
          rt.temp_var do |tv|
            tv.write recv_loc

            rt.temp_var do |argv|
              argv.write_address_of req.temp_stack[argc - 1]

              # Unwrap the proc object
              data_ptr = rt.pointer(tv, type: RData)

              rt.call_cfunc func_addr, [
                REG_EC,
                data_ptr.data,
                argc,
                argv,
                Fisk::Imm64.new(0),
                ->(dst) {
                  if req.has_block?
                    rt.load_address_in(dst, cfp_ptr.self)
                    rt.or dst, 0x01
                  else
                    rt.write(dst, Fisk::Imm64.new(0))
                  end
                }
              ], auto_align: false
            end
          end
          rt.jump jit_buffer.memory.to_i + return_loc
        end
      when rb.c("OPTIMIZED_METHOD_TYPE_BLOCK_CALL")
        # FIXME: We're assuming the BOP isn't redefined
        peek_ep = rb.VM_EP_LEP(RbControlFrameStruct.ep(cfp))
        block_handler = rb.VM_ENV_BLOCK_HANDLER(peek_ep)

        temp_stack = req.temp_stack

        with_runtime do |rt|
          # Adjust the stack for the block arg
          if req.has_blockarg?
            temp_stack = temp_stack.dup
            if temp_stack.peek(0).symbol?
              rt.call_cfunc symbol_addr("rb_sym_to_proc"), [temp_stack.pop]
              loc = temp_stack.push :proc
              rt.write loc, rt.return_value
            else
              raise NotImplementedError
            end
            temp_stack.freeze
          end

          argc.times do |i|
            raise NotImplementedError, "we need a test for this"
            rt.write temp_stack[i + 1], temp_stack[i]
          end

          case rb.vm_block_handler_type(block_handler)
          when rb.c("block_handler_type_iseq")
            # https://github.com/ruby/ruby/blob/cbf2078a25c3efb12f45b643a636ff7bb4d402b6/vm_insnhelper.c#L3307-L3309
            captured_block = rb.VM_BH_TO_ISEQ_BLOCK(block_handler)
            captured = rb.struct("rb_captured_block").new(captured_block)
            iseq_ptr = captured.code.iseq

            rt.flush

            compile_invokeblock_iseq_handler iseq_ptr, captured, return_loc, req, temp_stack
          when rb.c("block_handler_type_ifunc")
            raise
          when rb.c("block_handler_type_symbol")
            raise
          when rb.c("block_handler_type_proc")
            raise
          else
            raise "Unknown block handler type"
          end
          #rt.jump req.make_exit(exits, "unknown_method_type")
        end
      else
        puts RbMethodDefinitionStruct.new(cme.def).body.optimize_type
        raise NotImplementedError, "not supported optimized type"
      end
    end

    def compile_call_bmethod iseq, compile_request, argc, iseq_ptr, recv, cme, return_loc
      opt_pc     = 0 # we don't handle optional parameters rn
      proc_obj = RbMethodDefinitionStruct.new(cme.def).body.bmethod.proc
      proc = RData.new(proc_obj).data
      rb_block_t    = RbProcT.new(proc).block
      captured = rb_block_t.as.captured
      _self = recv

      param_size = iseq.body.param.size

      temp_stack = compile_request.temp_stack

      local_size = iseq.body.local_table_size - param_size

      overflow_exit = compile_request.make_exit(exits)

      recv_loc = temp_stack.peek(argc).loc

      with_runtime do |rt|
        ## Pop params and self from the stack
        rt.flush_pc_and_sp compile_request.next_pc, recv_loc
        rt.check_vm_stack_overflow compile_request.temp_stack, overflow_exit, local_size, iseq.body.stack_max
      end

      ts = temp_stack.dup

      with_runtime do |rt|
        Frames::BMethod.new(
          iseq.to_i,
          compile_request.temp_stack.peek(argc).loc,
          SpecVals::PreviousEP.new(captured.ep),
          cme,
          iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
          iseq.body.local_table_size - param_size, ts).push(rt)

        rt.push_reg REG_BP

        rt.temp_var do |var|
          var.write jit_buffer.memory.to_i + return_loc
          rt.push_reg var # Callee will `ret` to here

          # Dereference the JIT function address, skipping the REG_* assigments
          # and jump to it
          var.write iseq.body.to_i
          iseq_body = rt.pointer(var, type: RbIseqConstantBody)
          var.write iseq_body.jit_func
          rt.add var, @skip_bytes

          rt.jump var
        end
      end
    end

    def compile_expand_splat req, stack, temp_stack, return_loc
      ary_ptr = topn(stack, 0)
      rb_ary = Fiddle.dlunwrap(ary_ptr)

      temp_stack = temp_stack.dup

      with_runtime do |rt|
        rt.temp_var do |tmp|
          tmp.write temp_stack.pop

          # If the array seen at compile time is embedded, emit code for
          # an embedded array
          if rb.embedded_array?(ary_ptr)
            rt.if_embedded_array?(tmp) {
              rt.temp_var { |tmp2|
                rt.embedded_array_length(tmp, tmp2)
                rt.if_eq(tmp2, @fisk.imm(rb_ary.length)) {
                  array = rt.pointer(tmp, type: RArray)
                  rb_ary.length.times do |i|
                    rt.write temp_stack.push(:unknown), array.as.ary[i]
                  end
                }.else {
                  rt.patchable_jump req.deferred_entry
                  rt.jump jit_buffer.memory.to_i + return_loc
                }
              }
            }.else {
              # If the runtime value isn't embedded, recompile
              rt.patchable_jump req.deferred_entry
              rt.jump jit_buffer.memory.to_i + return_loc
            }
          else
            rt.if_embedded_array?(tmp) {
              # If the runtime value isn't extended, recompile
              rt.patchable_jump req.deferred_entry
              rt.jump jit_buffer.memory.to_i + return_loc
            }.else {
              rt.temp_var { |tmp2|
                rt.extended_array_length(tmp, tmp2)
                rt.if_eq(tmp2, @fisk.imm(rb_ary.length)) {
                  array = rt.pointer(tmp, type: RArray)
                  tmp2.write array.as.heap.ptr
                  array_buffer = rt.pointer(tmp2)

                  rb_ary.length.times do |i|
                    rt.write temp_stack.push(:unknown), array_buffer[i]
                  end
                }.else {
                  rt.patchable_jump req.deferred_entry
                  rt.jump jit_buffer.memory.to_i + return_loc
                }
              }
            }
          end
        end
      end
      temp_stack.freeze
    end

    def compile_send cfp, req, loc
      stack = RbControlFrameStruct.sp(cfp)

      ci = req.call_info
      mid = ci.vm_ci_mid
      argc = ci.vm_ci_argc
      temp_stack = req.temp_stack

      recv = topn(stack, argc)

      if req.has_blockarg?
        block_code = Fiddle::Pointer.new(stack - Fiddle::SIZEOF_VOIDP).ptr.to_i

        # https://github.com/ruby/ruby/blob/844588f9157b364244a7d34ee0fcc70ccc2a7dd9/vm_args.c#L889
        if rb.RB_SYMBOL_P(block_code) &&
            CFuncs.rb_method_basic_definition_p(rb.rb_class_of(block_code),
                                                CFuncs.rb_sym2id(Fiddle.dlwrap(:to_proc))) != 0
          cref = rb.vm_env_cref(RbControlFrameStruct.ep(cfp))
          if cref && !rb.NIL_P(rb.struct("rb_cref_t").refinements(cref))
            # We need to make this side-exit.  I don't want to support refinements
            raise NotImplementedError
          end
        else
          #proxy = Fiddle.read_ptr(Fiddle::Handle::DEFAULT["rb_block_param_proxy"], 0)
          #p rb.RB_SYMBOL_P(block_code)
          #puts proxy
          #puts block_code
          raise NotImplementedError
        end

        # adjust the stack.  The blockarg needs to be popped so argc lines up
        recv = topn(stack - Fiddle::SIZEOF_VOIDP, argc)
        temp_stack = req.temp_stack.dup
        temp_stack.pop
        temp_stack.freeze
      end

      patch_loc = loc - jit_buffer.memory.to_i
      return_loc = patch_loc + JMP_BYTES

      # Get the class of the receiver.  It could be an ICLASS if the object has
      # a singleton class.  This is important for doing method lookup (in case
      # of singleton methods).
      klass = rb.rb_class_of(recv)

      # Get the method definition
      cme_ptr = CFuncs.rb_callable_method_entry(klass, mid)

      # It the method isn't defined, use a side exit and return
      if cme_ptr.null?
        side_exit = req.make_exit(exits, "method_missing")
        patch_source_jump jit_buffer, at: patch_loc, to: side_exit
        return side_exit
      end

      # Get the method definition
      cme = RbCallableMethodEntryT.new(cme_ptr)
      method_definition = RbMethodDefinitionStruct.new(cme.def)

      method_entry_addr = nil

      case method_definition.type
      when VM_METHOD_TYPE_ISEQ
        # If we find an iseq method, compile it, even if we don't enter.
        iseq_ptr = RbMethodDefinitionStruct.new(cme.def).body.iseq.iseqptr.to_i
        iseq = RbISeqT.new(iseq_ptr)
        @jit.compile_iseq_t iseq_ptr

        if ci.splat?
          if simple_iseq?(iseq)
            callee_argc = iseq.body.param.size
            ary_ptr = topn(stack, 0)
            rb_ary = Fiddle.dlunwrap(ary_ptr)

            # bail if argc doesn't match up
            if callee_argc != (argc + rb_ary.length - 1)
              return complex_method_exit(req, patch_loc)
            end

            method_entry_addr = jit_buffer.address
            ts = temp_stack
            temp_stack = compile_expand_splat req, stack, temp_stack, return_loc

            temp_stack.freeze

            argc += (temp_stack.size - ts.size)
          else
            return complex_method_exit(req, patch_loc) if ci.splat?
          end
        end
      when VM_METHOD_TYPE_BMETHOD
        # If we find a bmethod method, compile the block iseq.
        proc_obj = RbMethodDefinitionStruct.new(cme.def).body.bmethod.proc
        proc = RData.new(proc_obj).data
        rb_block_t    = RbProcT.new(proc).block
        if rb_block_t.type != rb.c("block_type_iseq")
          raise NotImplementedError
        end

        iseq_ptr = rb_block_t.as.captured.code.iseq

        iseq = RbISeqT.new(iseq_ptr)

        @jit.compile_iseq_t iseq_ptr

        return complex_method_exit(req, patch_loc) if ci.splat?
      when VM_METHOD_TYPE_CFUNC
        # Only eagerly compile the blockiseq if the method type is a cfunc.
        # We can't lazily compile the block iseq because we don't know whether
        # or not the cfunc will call the block
        if req.has_block?
          if req.has_blockarg?
            # TODO: C function that takes a blockarg
            raise NotImplementedError
          end
          @jit.compile_iseq_t req.blockiseq
        end

        return complex_method_exit(req, patch_loc) if ci.splat?
      else

        return complex_method_exit(req, patch_loc) if ci.splat?
      end

      # If the call site has a block arg, and it's an iseq, lets compile it
      if req.has_blockarg?
        peek_ep = rb.VM_EP_LEP(RbControlFrameStruct.ep(cfp))
        block_handler = rb.VM_ENV_BLOCK_HANDLER(peek_ep)
        if rb.vm_block_handler_type(block_handler) == rb.c("block_handler_type_iseq")
          captured = rb.VM_BH_TO_ISEQ_BLOCK(block_handler)
          blockiseq = rb.struct("rb_captured_block").new(captured).code.iseq

          @jit.compile_iseq_t blockiseq
        end
      end

      # Bail on any method calls that aren't "simple".  Not handling *args,
      # kwargs, etc right now
      # If we're compiling a send that has a block, the "simple" ones are tagged
      # with VM_CALL_FCALL, otherwise we have to look for ARGS_SIMPLE
      return complex_method_exit(req, patch_loc) unless ci.supported_call?

      method_entry_addr ||= jit_buffer.address

      # Lift the address up to a Ruby object.  `recv` is the address of the
      # Ruby object, not the object itself.  Lets get the object itself so we
      # can perform tests on it.
      rb_recv = Fiddle.dlunwrap recv

      with_runtime do |rt|
        recv_loc = temp_stack.peek(argc).loc

        # If the compile time receiver is a special constant, we need to check
        # that it's still a special constant at runtime
        if rb.RB_SPECIAL_CONST_P(recv)
          # If the receiver is nil at compile time, make sure it's also nil
          # at runtime
          if rb_recv == nil
            rt.if_eq(recv_loc, Fiddle.dlwrap(nil)).else {
              rt.patchable_jump req.deferred_entry
              rt.jump jit_buffer.memory.to_i + return_loc
            }
          elsif rb_recv == false # Same here
            rt.if_eq(recv_loc, Fiddle.dlwrap(false)).else {
              rt.patchable_jump req.deferred_entry
              rt.jump jit_buffer.memory.to_i + return_loc
            }
          else # Otherwise it must be some other type of tagged pointer
            flags = recv & RUBY_IMMEDIATE_MASK

            tv = rt.temp_var
            tv.write recv_loc
            tv.and RUBY_IMMEDIATE_MASK

            rt.if_eq(tv.to_register, flags).else {
              rt.patchable_jump req.deferred_entry
              rt.jump jit_buffer.memory.to_i + return_loc
            }

            tv.release!
          end
        else
          rt.if(rt.RB_SPECIAL_CONST_P(recv_loc)) {
            rt.patchable_jump req.deferred_entry
            rt.jump jit_buffer.memory.to_i + return_loc
          }.else {

            tv = rt.temp_var
            tv.write recv_loc

            recv_ptr = rt.pointer(tv, type: RObject)

            rt.if_eq(RBasic.klass(recv), recv_ptr.basic.klass).else {
              rt.patchable_jump req.deferred_entry
              rt.jump jit_buffer.memory.to_i + return_loc
            }

            tv.release!
          }
        end
      end

      case method_definition.type
      when VM_METHOD_TYPE_ISEQ      # /*!< Ruby method */
        compile_call_iseq iseq, req, argc, iseq_ptr, recv, cme, temp_stack, return_loc
      when VM_METHOD_TYPE_CFUNC     # /*!< C method */
        compile_call_cfunc iseq, req, argc, iseq_ptr, recv, cme, return_loc
      when VM_METHOD_TYPE_BMETHOD
        compile_call_bmethod iseq, req, argc, iseq_ptr, recv, cme, return_loc
      when VM_METHOD_TYPE_OPTIMIZED # /*!< Kernel#send, Proc#call, etc */
        compile_call_optimized cfp, iseq, req, argc, iseq_ptr, recv, cme, ci, return_loc
      when VM_METHOD_TYPE_IVAR
        compile_call_ivar cfp, iseq, req, argc, iseq_ptr, recv, cme, return_loc
      else
        type = method_definition.type

        name = TenderJIT.constants.grep(/^VM_METHOD/).find { |n|
          TenderJIT.const_get(n) == type
        }.to_s.downcase

        method_entry_addr = req.make_exit(exits, name)
      end

      patch_source_jump jit_buffer, at: patch_loc, to: method_entry_addr

      method_entry_addr
    end

    def handle_nop; end

    def handle_newhash num
      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp

        if num == 0
          address = Fiddle::Handle::DEFAULT["rb_hash_new"]
          ret = rt.call_cfunc(address, [])
          rt.push ret, name: "hash"
        else
          rt.flush_pc_and_sp next_pc, @temp_stack.first.loc

          # Allocate the hash
          address = Fiddle::Handle::DEFAULT["rb_hash_new_with_size"]
          ret = rt.call_cfunc(address, [num / 2])

          # Write the hash reference to a temporary register.
          rt.temp_var do |hash|
            hash.write ret

            values_loc = @temp_stack.peek(num - 1).loc

            rt.with_ref(values_loc) do |ref|
              num.times { @temp_stack.pop }

              # Fill the hash
              address = Fiddle::Handle::DEFAULT["rb_hash_bulk_insert"]
              rt.push_reg hash
              rt.call_cfunc address, [num, ref, hash], auto_align: false
              rt.pop_reg hash
              rt.push hash, name: "hash"
            end
          end
        end
      end
    end

    def handle_newarray num
      address = Fiddle::Handle::DEFAULT["rb_ec_ary_new_from_values"]

      with_runtime do |rt|
        rt.push_reg REG_BP

        # GC could be triggered
        rt.flush_sp

        values_loc = if num > 0
          @temp_stack.peek(num - 1).loc
        else
          # When there are no values to create an array from, there is no
          # meaningful address to pass; MRI doesn't use the address in this case
          # (see https://github.com/ruby/ruby/blob/v3_0_2/array.c#L838).
          # For simplicity/safety, we send a null pointer.
          #
          Fisk::Imm64.new(0)
        end

        rt.with_ref(values_loc) do |ref|
          num.times { @temp_stack.pop }
          ret = rt.call_cfunc address, [REG_EC, num, ref], auto_align: false
          rt.push ret, name: "array"
        end

        rt.pop_reg REG_BP # magic
      end
    end

    # params:
    # - `flag`: end exclusion; see `range.c#range_init()`.
    def handle_newrange flag
      rb_range_new = Fiddle::Handle::DEFAULT["rb_range_new"]

      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp

        high = @temp_stack.pop
        low = @temp_stack.pop

        rt.call_cfunc rb_range_new, [low, high, flag]
        rt.push rt.return_value, name: :range
      end
    end

    def handle_duparray ary
      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp
        rt.call_cfunc Fiddle::Handle::DEFAULT["rb_ary_resurrect"], [Fisk::Imm64.new(ary)]
        rt.push rt.return_value, name: RUBY_T_ARRAY
      end
    end

    def handle_duphash hash
      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp
        rt.call_cfunc Fiddle::Handle::DEFAULT["rb_hash_resurrect"], [Fisk::Imm64.new(hash)]
        rt.push rt.return_value, name: RUBY_T_HASH
      end
    end

    def handle_tostring
      rb_obj_as_string_result = Fiddle::Handle::DEFAULT["rb_obj_as_string_result"]

      with_runtime do |rt|
        # GC could be triggered
        rt.flush_sp

        str = @temp_stack.pop
        val = @temp_stack.pop

        rt.call_cfunc rb_obj_as_string_result, [str, val]
        rt.push rt.return_value, name: RUBY_T_STRING
      end
    end

    # params:
    # - `opt`: used to interpolate the string(s) - see `rb_reg_initialize_str()`
    # - `cnt`: number of values; they're at least 2 - when only one expression is
    #          interpolated (e.g. `/#{foo/`), an empty string is pushed first to
    #          the stack.
    def handle_toregexp opt, cnt
      rb_ary_tmp_new_from_values = Fiddle::Handle::DEFAULT["rb_ary_tmp_new_from_values"]
      rb_reg_new_ary = Fiddle::Handle::DEFAULT["rb_reg_new_ary"]
      rb_ary_clear = Fiddle::Handle::DEFAULT["rb_ary_clear"]

      with_runtime do |rt|
        rt.with_ref(@temp_stack.peek(cnt - 1).loc) do |stack_addr_from_top|
          # This instruction can raise RegexpError, so we need the CFP to have
          # up-to-date PC/SP.  Also GC can be triggered
          if @temp_stack.size == 0
            rt.flush_pc_and_sp next_pc, REG_BP
          else
            rt.flush_pc_and_sp next_pc, @temp_stack.peek(0).loc
          end

          result = @temp_stack.push :regexp

          rt.temp_var do |ary|
            rt.call_cfunc rb_ary_tmp_new_from_values, [0, cnt, stack_addr_from_top]
            ary.write rt.return_value

            rt.call_cfunc rb_reg_new_ary, [ary, opt]
            rt.write result, rt.return_value

            rt.call_cfunc rb_ary_clear, [ary]
          end
        end
      end
    end

    def handle_intern
      rb_str_intern = Fiddle::Handle::DEFAULT["rb_str_intern"]

      with_runtime do |rt|
        # GC can be triggered
        rt.flush_sp

        str = @temp_stack.pop

        rt.call_cfunc rb_str_intern, [str]
        rt.push rt.return_value, name: RUBY_T_SYMBOL
      end
    end

    class BranchUnless < Struct.new(:jump_idx, :jump_type, :temp_stack)
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

      read_loc = @temp_stack.pop

      patch_request = BranchUnless.new jump_pc, :jz, @temp_stack.dup.freeze
      @compile_requests << Fiddle::Pinned.new(patch_request)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_jump, [REG_CFP, patch_request, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      flush

      deferred.call

      # FIXME: should we teach patchable_jump about jz?
      __.test(read_loc, __.imm(~Qnil))
        .lea(__.rax, __.rip)
        .jz(__.absolute(deferred.entry.to_i))

      :continue # create a new block and keep compiling
    end

    class BranchIf < Struct.new(:jump_idx, :jump_type, :temp_stack)
    end

    def handle_branchif dst
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      jump_idx = @insn_idx + dst + len

      # if this is a backwards jump, check interrupts
      if jump_idx < @insn_idx
        exit_addr = exits.make_exit(insn_name, current_pc, @temp_stack.size)

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

      __.test(@temp_stack.pop, __.imm(~Qnil))

      flush

      target_jump_block = @blocks.find { |b| b.entry_idx == jump_idx }

      patch_false = BranchIf.new next_idx, :jmp, @temp_stack.dup.freeze
      @compile_requests << Fiddle::Pinned.new(patch_false)

      patch_true = BranchIf.new jump_idx, :jnz, @temp_stack.dup.freeze
      @compile_requests << Fiddle::Pinned.new(patch_true)

      deferred_true, deferred_false = [patch_true, patch_false].map do |patch|
        req = @jit.deferred_call(@temp_stack) do |ctx|
          ctx.with_runtime do |rt|
            rt.rb_funcall self, :compile_jump, [REG_CFP, patch, rt.return_value]

            rt.NUM2INT(rt.return_value)

            rt.jump rt.return_value
          end
        end

        req.call
        req
      end

      with_runtime do |rt|
        if target_jump_block
          jit_buffer.write_jump to: target_jump_block.start_address,
            type: :jnz
        else
          # Jump if value is true
          rt.patchable_jump deferred_true.entry, type: :jnz
        end

        rt.patchable_jump deferred_false.entry
      end

      :stop
    end

    class HandleOptGetinlinecache < Struct.new(:jump_idx, :jump_type, :temp_stack, :ic, :current_pc)
    end

    def compile_opt_getinlinecache cfp, req, patch_loc
      patch_loc = patch_loc - jit_buffer.memory.to_i

      stack = req.temp_stack.dup

      loc = stack.push(:cache_get)

      # Find the next block we'll jump to
      target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }

      unless target_block
        exit_addr = exits.make_exit("temporary_exit", req.current_pc, req.temp_stack.size)

        jit_buffer.patch_jump at: patch_loc,
                              to: exit_addr,
                              type: req.jump_type

        resume_compiling req.jump_idx, stack
        target_block = @blocks.find { |b| b.entry_idx == req.jump_idx }
      end

      raise unless target_block.done?

      jit_buffer.patch_jump at: patch_loc,
                            to: jit_buffer.address,
                            type: req.jump_type

      jump_location = jit_buffer.address

      with_runtime do |rt|
        ## Write the constant value to the stack
        rt.write loc, IseqInlineConstantCache.new(req.ic).entry.value

        rt.jump target_block.start_address
      end

      jump_location
    end

    def handle_opt_getinlinecache dst, ic
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      dst = @insn_idx + dst + len

      patch_request = HandleOptGetinlinecache.new dst, :jmp, @temp_stack.dup.freeze, ic, current_pc
      @compile_requests << Fiddle::Pinned.new(patch_request)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_opt_getinlinecache, [REG_CFP, patch_request, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      loc = @temp_stack.push(:cache_get)

      ary_head = Fiddle::Pointer.new(CONST_WATCHERS)
      watcher_count = ary_head[0, Fiddle::SIZEOF_VOIDP].unpack1("l!")
      watchers = ary_head[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP * watcher_count].unpack("l!#{watcher_count}")

      __.lea(__.rax, __.rip)

      flush

      watch_address = jit_buffer.address

      __.jmp(__.label(:next))
        .put_label(:next)
        .with_register { |tmp|
          __.mov(tmp, __.uimm(ic))
            .mov(tmp, __.m64(tmp, IseqInlineConstantCache.offsetof("entry")))
            .test(tmp, tmp)
            .jz(__.label(:continue)) # no entry
          __.with_register { |global|
            __.mov(global, __.uimm(Fiddle::Handle::DEFAULT["ruby_vm_global_constant_state"]))
              .mov(global, __.m64(global))
              .cmp(global, __.m64(tmp, IseqInlineConstantCacheEntry.offsetof("ic_serial")))
              .jne(__.label(:continue)) # doesn't match
              .jmp(__.absolute(deferred.entry))
          }
        }

      __.put_label(:continue)
        .mov(loc, __.uimm(Qnil))

      flush

      # the global constant changed handler will patch the jump instruction
      # at the "watch_address" and we don't need to invalidate the entire iseq
      watchers << watch_address
      ary_head[0, Fiddle::SIZEOF_VOIDP] = [watchers.length].pack("q")
      buf = watchers.pack("q*")
      ary_head[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP * watchers.length] = buf

      :continue
    end

    class HandleJump < Struct.new(:jump_idx, :jump_type, :temp_stack)
    end

    def handle_jump dst
      insn = @insns[@insn_idx]
      len    = rb.insn_len(insn)

      dst = @insn_idx + dst + len

      patch_request = HandleJump.new dst, :jmp, @temp_stack.dup.freeze
      @compile_requests << Fiddle::Pinned.new(patch_request)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_jump, [REG_CFP, patch_request, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      with_runtime { |rt| rt.patchable_jump deferred.entry }

      :stop
    end

    def handle_putnil
      with_runtime do |rt|
        rt.push Fisk::Imm64.new(Qnil), name: T_NIL
      end
    end

    def handle_pop
      @temp_stack.pop
    end

    def handle_opt_minus call_data
      ts = @temp_stack

      exit_addr = exits.make_exit("opt_minus", current_pc, @temp_stack.size)

      # Generate runtime checks if we need them
      2.times do |i|
        if ts.peek(i).type != T_FIXNUM
          # Is the argument a fixnum?
          __.test(ts.peek(i).loc, __.uimm(rb.c("RUBY_FIXNUM_FLAG")))
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
        if ts.peek(i).type != T_FIXNUM
          # Is the argument a fixnum?
          __.test(ts.peek(i).loc, __.uimm(rb.c("RUBY_FIXNUM_FLAG")))
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

    def handle_opt_mult call_data
      ts = @temp_stack

      _exit_addr = exits.make_exit("opt_mult", current_pc, @temp_stack.size)

      # Generate runtime checks if we need them
      2.times do |i|
        if ts.peek(i).type != T_FIXNUM
          return handle_opt_send_without_block(call_data)
        end
      end

      rhs_loc = ts.pop
      lhs_loc = ts.pop

      with_runtime do |rt|
        val = rt.mult(rhs_loc, lhs_loc)
        rt.push(val, name: T_FIXNUM)
      end
    end

    def handle_opt_div call_data
      perform_division(call_data) do |rt, dividend, divisor|
        rt.div dividend, divisor
      end
    end

    def handle_opt_mod call_data
      perform_division(call_data) do |rt, dividend, divisor|
        rt.mod dividend, divisor
      end
    end

    # Performs a division operation (div/mod); the actual operation needs to be
    # invoked inside the yielded block.
    #
    # Exits if the two values are not FIXNUMs.
    #
    # Used by `opt_div` and `opt_mod`.
    #
    def perform_division(call_data, &block)
      _exit_addr = exits.make_exit "opt_div", current_pc, @temp_stack.size

      2.times do |i|
        if @temp_stack.peek(i).type != T_FIXNUM
          return handle_opt_send_without_block call_data
        end
      end

      divisor = @temp_stack.pop
      dividend = @temp_stack.pop

      with_runtime do |rt|
        result_reg = yield rt, dividend, divisor

        rt.push result_reg, name: T_FIXNUM
      end
    end
    private :perform_division

    # Guard stack types. They need to be in "stack" order (backwards)
    def guard_two_fixnum
      ts = @temp_stack

      exit_addr = nil

      # Generate runtime checks if we need them
      2.times do |i|
        if ts.peek(i).type != T_FIXNUM
          exit_addr ||= exits.make_exit(insn_name, current_pc, @temp_stack.size)

          # Is the argument a fixnum?
          __.test(ts.peek(i).loc, __.uimm(rb.c("RUBY_FIXNUM_FLAG")))
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

    def handle_opt_eq call_data
      handle_opt_send_without_block call_data
    end

    def handle_opt_not call_data
      handle_opt_send_without_block call_data
    end

    def handle_opt_length call_data
      handle_opt_send_without_block call_data
    end

    def handle_opt_succ call_data
      value = @temp_stack.peek(0).loc

      _exit_addr = exits.make_exit("opt_succ", current_pc, @temp_stack.size)

      if value.type != T_FIXNUM
        return handle_opt_send_without_block(call_data)
      end

      with_runtime do |rt|
        # Note that it's possible also to operate directly on the memory, without
        # moving to a register (which is also simpler), although, in principle,
        # it's slower.
        #
        rt.temp_var do |value_reg|
          value_reg.write value

          rt.NUM2INT value_reg
          rt.inc value_reg.to_register
          rt.INT2NUM value_reg

          rt.write value, value_reg
        end
      end
    end

    def handle_putobject_INT2FIX_1_
      with_runtime do |rt|
        rt.push Fisk::Imm64.new(0x3), name: 1, type: T_FIXNUM
      end
    end

    def handle_putobject_INT2FIX_0_
      with_runtime do |rt|
        rt.push Fisk::Imm64.new(0x1), name: 0, type: T_FIXNUM
      end
    end

    def handle_setlocal_WC_0 idx
      addr = exits.make_exit("setlocal_WC_0", current_pc, @temp_stack.size)

      loc = @temp_stack.pop

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
      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)
        rt.temp_var do |temp|

          # Get the local value from the EP
          temp.write cfp_ptr.ep

          # dereference the temp var
          temp.write temp[-idx]

          # push it on the stack
          rt.push temp, name: :local
        end

        rt.flush
      end
    end

    def handle_setlocal_WC_1 idx
      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)
        rt.temp_var do |temp|

          # Get the current EP
          temp.write cfp_ptr.ep

          # Get the previous EP (WC_1 == "1 previous")
          temp.write temp[VM_ENV_DATA_INDEX_SPECVAL]

          temp.and(~0x3)

          # Write the local
          temp[-idx] = @temp_stack.pop
        end

        rt.flush
      end
    end

    def handle_getlocal_WC_1 idx
      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)
        rt.temp_var do |temp|

          # Get the local value from the EP
          temp.write cfp_ptr.ep

          temp.write temp[VM_ENV_DATA_INDEX_SPECVAL]

          temp.and(~0x3)

          temp.sub idx

          # dereference the temp var
          temp.write temp[0]

          # push it on the stack
          rt.push temp, name: :local
        end

        rt.flush
      end
    end

    def handle_putself
      with_runtime do |rt|
        # Get self from the CFP
        rt.push Fisk::M64.new(REG_CFP, RbControlFrameStruct.offsetof("self")), name: "self"
      end
    end

    def handle_putobject literal
      object_type = rb.rb_type literal

      with_runtime do |rt|
        rt.push literal, name: :literal, type: object_type
      end
    end

    # `leave` instruction
    def handle_leave
      # FIXME: We need to check interrupts and exit

      stack_top = @temp_stack.pop

      with_runtime do |rt|
        # Copy top value from the stack in to rax
        rt.write Fisk::Registers::RAX, stack_top

        # Pop the frame from the stack
        rt.add REG_CFP, RbControlFrameStruct.byte_size

        # Write the frame pointer back to the ec
        rt.write Fisk::M64.new(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP

        rt.return
      end

      :stop
    end

    def handle_concatarray
      ary2_loc = @temp_stack.pop
      ary1_loc = @temp_stack.pop

      vm_concat_array ary1_loc, ary2_loc
    end

    def vm_concat_array ary1_loc, ary2_loc
      check_cfunc_addr = Fiddle::Handle::DEFAULT["rb_check_to_array"]
      newarray_cfunc_addr = Fiddle::Handle::DEFAULT["rb_ary_new_from_args"]
      concat_cfunc_addr = Fiddle::Handle::DEFAULT["rb_ary_concat"]

      with_runtime do |rt|
        # Flush the PC and SP to the current frame.  The functions we call
        # below can cause the GC to execute, can possibly call back out to
        # Ruby, and can also possibly raise an exception.  We need the CFP to
        # have an up-to-date PC and SP so that a) the GC can find any
        # references it needs to keep alive, b) if something raises an
        # exception the stack trace is correct, and c) any calls back in to
        # Ruby will not clobber our stack.
        if @temp_stack.size == 0
          rt.flush_pc_and_sp next_pc, REG_BP
        else
          rt.flush_pc_and_sp next_pc, @temp_stack.peek(0).length
        end

        # Allocate and set tmp1 #####################################

        rt.temp_var do |tmp1_loc| # Allocate a temp variable
          rt.push_reg REG_BP # Alignment push

          tmp1_val = rt.call_cfunc check_cfunc_addr, [ary1_loc], auto_align: false

          rt.if_eq(tmp1_val.to_register, Fisk::Imm64.new(Qnil)) {
            tmp1_val = rt.call_cfunc newarray_cfunc_addr, [Fisk::Imm64.new(1), ary1_loc], auto_align: false
          }.else {}

          rt.pop_reg REG_BP # Alignment pop

          # tmp1_val is the RAX register.  We need to save its value in a temp
          # register before we can call another function (as the next function
          # will clobber the value in the RAX register)
          tmp1_loc.write tmp1_val

          # Allocate and set tmp2 #####################################

          rt.temp_var do |tmp2_loc|
            rt.push_reg tmp1_loc # Push for alignment, but also save the tmp

            tmp2_val = rt.call_cfunc check_cfunc_addr, [ary2_loc], auto_align: false

            rt.if_eq(tmp2_val, Fisk::Imm64.new(Qnil)) {
              tmp2_val = rt.call_cfunc newarray_cfunc_addr, [Fisk::Imm64.new(1), ary2_loc], auto_align: false
            }.else {}

            rt.pop_reg tmp1_loc # Pop for alignment, but restore the tmp

            # Same deal here. Calling the C function will clobber RAX
            tmp2_loc.write tmp2_val

            # Compute the result, and cleanup ###########################

            result_val = rt.call_cfunc concat_cfunc_addr, [tmp1_loc, tmp2_loc], auto_align: false
            result_loc = @temp_stack.push :array
            rt.write result_loc, result_val
          end
        end
      end
    end

    def handle_splatarray flag
      with_runtime do |rt|
        # GC can be triggered
        rt.flush_sp
      end

      pop_loc = @temp_stack.pop
      push_loc = @temp_stack.push(:object, type: T_ARRAY)

      vm_splat_array pop_loc, push_loc, flag
    end

    def vm_splat_array read_loc, store_loc, flag
      with_runtime do |rt|
        rb_check_to_array = symbol_addr("rb_check_to_array")
        rb_ary_new_from_args = symbol_addr("rb_ary_new_from_args")
        rb_ary_dup = symbol_addr("rb_ary_dup")

        rt.call_cfunc rb_check_to_array, [read_loc]

        # If it returned nil, make a new array
        rt.if_eq(rt.return_value, Fisk::Imm64.new(Qnil)) {
          rt.call_cfunc rb_ary_new_from_args, [1, rt.return_value]
        }.else {
          rt.temp_var do |truthy_flag|
            # RTEST (truthy test): (value & !Qnil)
            truthy_flag.write flag
            truthy_flag.and ~Qnil

            rt.if(truthy_flag.to_register) {
              # The input value is still in RAX, since the logical operations are
              # performend on other registers.
              rt.call_cfunc rb_ary_dup, [rt.return_value]
            }.else {}
          end
        }

        rt.write store_loc, rt.return_value
      end
    end

    def handle_swap
      top_item = @temp_stack.pop_item
      second_item = @temp_stack.pop_item

      with_runtime do |rt|
        rt.temp_var do |tv|
          # Keep the second item in a temporary location
          tv.write second_item.loc

          loc = @temp_stack.push(top_item.name, type: top_item.type)
          rt.write loc, top_item.loc

          loc = @temp_stack.push(second_item.name, type: second_item.type)
          rt.write loc, tv
        end
      end
    end

    def handle_opt_aset call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      argc = ci.vm_ci_argc
      return :quit unless argc == 2

      # only handle simple methods
      #return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      req = CompileOptAref.new
      req.call_info = ci
      req.temp_stack = @temp_stack.dup.freeze
      req.current_pc = current_pc
      req.next_pc = next_pc

      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_opt_aset, [REG_CFP, req, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      req.deferred_entry = deferred.entry.to_i

      (argc + 1).times { @temp_stack.pop }

      #Jump in to the deferred compiler
      with_runtime { |rt|
        rt.patchable_jump deferred.entry
        # The call will return here, and its return value will be in RAX
        loc = @temp_stack.push(:unknown)
        rt.write loc, rt.return_value
      }
    end

    def handle_setn n
      item = @temp_stack.peek(0)
      with_runtime do |rt|
        rt.write @temp_stack.peek(n).loc, item.loc
      end
    end

    def handle_dupn num
      from_top = @temp_stack.first(num)
      with_runtime do |rt|
        from_top.each do |item|
          rt.push item.loc, name: item.name, type: item.type
        end
      end
    end

    def handle_adjuststack n
      n.times { @temp_stack.pop }
    end

    class GetBlockParamProxy < Struct.new(:idx, :level, :temp_stack, :deferred_entry, :exit_addr)
    end

    def compile_getblockparamproxy cfp, req, loc
      peek_ep = RbControlFrameStruct.ep(cfp)

      patch_loc  = loc - jit_buffer.memory.to_i
      return_loc = patch_loc + JMP_BYTES
      entry_loc  = jit_buffer.address

      peek_ep = rb.vm_get_ep peek_ep, req.level
      raise "EP is wrong!" unless rb.VM_ENV_LOCAL_P(peek_ep)
      if !rb.VM_ENV_FLAGS(peek_ep, VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM)
        temp_stack = req.temp_stack.dup

        push_loc = temp_stack.push("proc", type: T_DATA)

        with_runtime(temp_stack, alignment: 0) do |rt|
          rt.flush_sp

          rt.temp_var do |ep|
            rt.pop_reg ep

            ep_ptr = rt.pointer(ep)

            block_handler = rb.VM_ENV_BLOCK_HANDLER(peek_ep)

            case rb.vm_block_handler_type(block_handler)
            when rb.c("block_handler_type_iseq"), rb.c("block_handler_type_ifunc")
              proxy = Fiddle.read_ptr(Fiddle::Handle::DEFAULT["rb_block_param_proxy"], 0)
              rt.write push_loc, proxy
            when rb.c("block_handler_type_symbol")
              rt.if(rt.VM_ENV_FLAG_SET_P(ep, VM_ENV_FLAG_WB_REQUIRED)) {
                # We need to execute a write barrier, so lets exit back to
                # the interpreter
                rt.jump req.exit_addr
              }.endif

              if rb.RB_STATIC_SYM_P(block_handler)
                rt.if(rt.RB_STATIC_SYM_P(ep_ptr[VM_ENV_DATA_INDEX_SPECVAL])) {
                  addr = Fiddle::Handle::DEFAULT["rb_sym_to_proc"]
                  rt.call_cfunc(addr, [ep_ptr[VM_ENV_DATA_INDEX_SPECVAL]])
                  # Set the block handler in EP
                  ep_ptr[-req.idx] = rt.return_value
                  rt.write push_loc, rt.return_value
                }.else {
                  rt.push_reg ep
                  rt.patchable_jump req.deferred_entry
                }
              else
                rt.if(rt.RB_STATIC_SYM_P(ep_ptr[VM_ENV_DATA_INDEX_SPECVAL])) {
                  rt.push_reg ep
                  rt.patchable_jump req.deferred_entry
                }.else {
                  addr = Fiddle::Handle::DEFAULT["rb_sym_to_proc"]
                  rt.call_cfunc(addr, [ep_ptr[VM_ENV_DATA_INDEX_SPECVAL]])
                  # Set the block handler in EP
                  ep_ptr[-req.idx] = rt.return_value
                  rt.write push_loc, rt.return_value
                }
              end
            when rb.c("block_handler_type_proc")
              # I'm not sure how to make this one happen
              raise NotImplementedError
            end
          end

          rt.jump jit_buffer.memory.to_i + return_loc
        end
      else
        raise "Unreachable"
      end

      patch_source_jump jit_buffer, at: patch_loc, to: entry_loc

      entry_loc
    end

    def handle_getblockparamproxy idx, level
      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

        rt.temp_var("EP") do |ep|
          req = GetBlockParamProxy.new idx, level, @temp_stack.dup.freeze
          @compile_requests << Fiddle::Pinned.new(req)

          req.exit_addr = exits.make_exit("getblockparamproxy", current_pc, @temp_stack.size)

          push_loc = @temp_stack.push("proc", type: T_DATA)

          ep.write cfp_ptr.ep
          rt.vm_get_ep(ep, level)

          rt.if(rt.VM_ENV_FLAG_SET_P(ep, VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM)) {
            # It's already been modified, so use the modified value
            ep_ptr = rt.pointer(ep)
            rt.write push_loc, ep_ptr[-idx]
          }.else {
            deferred = @jit.deferred_call(@temp_stack) do |ctx|
              ctx.with_runtime do |rt|
                # We pushed before calling the patchable jump,
                # so this function call should already be aligned
                rt.rb_funcall self, :compile_getblockparamproxy, [REG_CFP, req, rt.return_value], auto_align: false
                rt.NUM2INT(rt.return_value)

                rt.jump rt.return_value
              end
            end

            req.deferred_entry = deferred.entry.to_i
            deferred.call

            rt.push_reg ep
            rt.patchable_jump deferred.entry
          }
        end
      end
    end

    def handle_getblockparam idx, level
      exit_addr = exits.make_exit("getblockparam", current_pc, @temp_stack.size)
      push_loc = @temp_stack.push("proc", type: T_DATA)

      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)
        rt.temp_var do |ep|
          ep.write cfp_ptr.ep
          rt.vm_get_ep(ep, level)

          rt.if(rt.VM_ENV_FLAG_SET_P(ep, VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM)) {
            # It's already been modified, so use the modified value
            ep_ptr = rt.pointer(ep)
            rt.write push_loc, ep_ptr[-idx]
          }.else {
            rt.if(rt.VM_ENV_FLAG_SET_P(ep, VM_ENV_FLAG_WB_REQUIRED)) {
              # We need to execute a write barrier, so lets exit back to
              # the interpreter
              rt.jump exit_addr
            }.else {
              # Convert the block handler to a proc
              ep_ptr = rt.pointer(ep)
              func_addr = rb.symbol_address("rb_vm_bh_to_procval")

              # Push EP because calling the cfunc will clobber our register.
              # NB: EP is pushed automatically because of "preserve_temp_var_regs"
              rt.call_cfunc func_addr, [REG_EC, ep_ptr[VM_ENV_DATA_INDEX_SPECVAL]], auto_align: false

              # Set the block handler in EP
              ep_ptr[-idx] = rt.return_value
              rt.write push_loc, rt.return_value
              rt.VM_ENV_FLAGS_SET(ep, VM_FRAME_FLAG_MODIFIED_BLOCK_PARAM)
            }
          }
        end
      end
    end

    class CompileExpandArray < Struct.new(:num, :flag, :temp_stack, :deferred_entry)
    end

    def compile_embedded_expandarray rt, req, tmp, stack_top
      rt.temp_var { |tmp2|
        rt.temp_var { |stack|
          # Push the array reference on the stack so we can get it again later
          rt.push_reg tmp

          rt.embedded_array_length(tmp, tmp)

          rt.if(tmp, :>=, req.num) {
            # Get the array back
            rt.pop_reg tmp

            # Get the buffer for the embedded array
            rt.embedded_array_buffer(tmp, tmp)

            (req.num - 1).downto(0) do |i|
              rt.push rt.buffer_ref(tmp, i), name: "array ref"
            end

          }.else {
            # number of nils to push = tmp - req.num
            rt.write tmp2, req.num
            rt.sub tmp2, tmp

            # Copy the stack top to a temp reg
            rt.load_address_in stack, stack_top

            rt.while(tmp2) {
              rt.write_memory stack.to_register, 0, @fisk.imm(Qnil)
              rt.add stack, Fiddle::SIZEOF_VOIDP
              rt.dec(tmp2)
            }

            # Get the array reference back
            rt.pop_reg tmp2

            # Get the buffer for the embedded array
            rt.embedded_array_buffer(tmp2, tmp2)

            # Push to the end of the array
            rt.push_reg stack
            rt.write stack, tmp
            rt.mult stack, Fiddle::SIZEOF_VOIDP, stack
            rt.add tmp2, stack
            rt.sub tmp2, Fiddle::SIZEOF_VOIDP
            rt.pop_reg stack

            rt.while(tmp) {
              rt.push_reg tmp2
              rt.load_from_reg tmp2.to_register, 0, tmp2.to_register
              rt.write_to_mem stack.to_register, 0, tmp2.to_register
              rt.pop_reg tmp2
              rt.add stack, Fiddle::SIZEOF_VOIDP
              rt.sub tmp2, Fiddle::SIZEOF_VOIDP
              rt.dec(tmp)
            }
          }
        }
      }
    end

    def compile_expandarray cfp, req, loc
      stack = RbControlFrameStruct.sp(cfp)

      patch_loc = loc - jit_buffer.memory.to_i
      return_loc = patch_loc + JMP_BYTES

      # Get the top of the runtime stack
      seen_ptr = Fiddle.read_ptr(stack, -Fiddle::SIZEOF_VOIDP)

      temp_stack = req.temp_stack.dup

      stack_top = temp_stack.pop

      entry_loc  = jit_buffer.address

      with_runtime(temp_stack) do |rt|
        # Is this a tagged pointer?  See `handle_expandarray`
        if seen_ptr & 1 == 1
          rt.if_test_bit(stack_top, 1) {
            rt.temp_var { |tmp|
              tmp.write stack_top

              # clear the tag bit
              rt.and(tmp.to_register, ~1)
              compile_embedded_expandarray(rt, req, tmp, stack_top)
            }
            # Remove the machine stack allocated "Ruby object"
            rt.add @fisk.rsp, RUBY_OBJECT_ON_STACK_SIZE

          }.else {
            # recompile
            rt.patchable_jump req.deferred_entry

            # FIXME: It's weird that as we compile things we'll have to jump
            # back here, then jump back to the origin.  It would be nice to
            # directly jump back to the origin.  I need to figure out a way
            # to do that.
          }
        else
          raise "This should never happen" unless rb.rb_type(seen_ptr) == T_ARRAY

          # Compile time check
          if rb.embedded_array?(seen_ptr)
            rt.temp_var { |tmp|
              # Dereference the stack top to get the array
              tmp.write stack_top

              # Verify the compile time check
              rt.if_embedded_array?(tmp) {
                compile_embedded_expandarray(rt, req, tmp, stack_top)
              }.else {
                # recompile
                rt.patchable_jump req.deferred_entry

                # FIXME: Same as above fixme
              }
            }
          else
            rt.temp_var { |tmp|
              tmp.write stack_top

              rt.if_extended_array?(tmp) {
                # Write the array length in to the `len` register
                rt.extended_array_length(stack_top, tmp)

                rt.if(tmp, :>=, req.num) {
                  # Get the buffer for the extended array
                  rt.extended_array_buffer(stack_top, tmp)

                  (req.num - 1).downto(0) do |i|
                    rt.push rt.buffer_ref(tmp, i), name: "array ref"
                  end
                }.else {
                  rt.temp_var { |tmp2|
                    rt.temp_var { |stack|
                      # number of nils to push = tmp - req.num
                      rt.write tmp2, req.num
                      rt.sub tmp2, tmp

                      # Dereference the stack top to get the array
                      rt.write stack, stack_top

                      # Push the array reference on the stack so we can get it again later
                      rt.push_reg stack

                      # Copy the stack top to a temp reg
                      rt.load_address_in stack, stack_top

                      rt.while(tmp2) {
                        rt.write_memory stack.to_register, 0, @fisk.imm(Qnil)
                        rt.add stack, Fiddle::SIZEOF_VOIDP
                        rt.dec(tmp2)
                      }

                      # Get the array reference back
                      rt.pop_reg tmp2

                      # Get the buffer for the embedded array
                      rt.extended_array_buffer(tmp2, tmp2)

                      # Push to the end of the array
                      rt.push_reg stack
                      rt.write stack, tmp
                      rt.mult stack, Fiddle::SIZEOF_VOIDP, stack
                      rt.add tmp2, stack
                      rt.sub tmp2, Fiddle::SIZEOF_VOIDP
                      rt.pop_reg stack

                      rt.while(tmp) {
                        rt.push_reg tmp2
                        rt.load_from_reg tmp2.to_register, 0, tmp2.to_register
                        rt.write_to_mem stack.to_register, 0, tmp2.to_register
                        rt.pop_reg tmp2
                        rt.add stack, Fiddle::SIZEOF_VOIDP
                        rt.sub tmp2, Fiddle::SIZEOF_VOIDP
                        rt.dec(tmp)
                      }
                    }
                  }
                }
              }.else {
                # recompile
                rt.patchable_jump req.deferred_entry
                # FIXME: see above
              }
            }
          end
        end

        # great!
        rt.jump jit_buffer.memory.to_i + return_loc
      end

      patch_source_jump jit_buffer, at: patch_loc, to: entry_loc

      entry_loc
    end

    RUBY_OBJECT_ON_STACK_SIZE = 48

    def compile_push_stack_array rt
      loc = @temp_stack.pop

      write_loc = @temp_stack.push :unknown
      # Allocate a fake embedded array on the stack
      rt.temp_var do |tmp|
        rt.sub @fisk.rsp, RUBY_OBJECT_ON_STACK_SIZE
        rt.write tmp, @fisk.rsp
        rt.add tmp, Fiddle::SIZEOF_VOIDP

        flags = Ruby::T_ARRAY |
          (Ruby::RARRAY_EMBED_FLAG) |
          (3 << Ruby::RARRAY_EMBED_LEN_SHIFT)

        rt.write_to_mem(tmp, RBasic.offsetof("flags"), flags)
        rt.write(rt.pointer(tmp, type: RArray).as.ary[0], loc)
        rt.write(rt.pointer(tmp, type: RArray).as.ary[1], Qnil)
        rt.write(rt.pointer(tmp, type: RArray).as.ary[2], Qnil)

        # Make it look like an integer so that the GC won't try to mark
        rt.inc tmp
        rt.write write_loc, tmp
      end
    end

    def handle_coercearray
      addr = Fiddle::Handle::DEFAULT["rb_check_array_type"]

      loc = @temp_stack.pop
      write_loc = @temp_stack.push :unknown
      with_runtime do |rt|
        rt.if(rt.RB_SPECIAL_CONST_P(loc)) {
          rt.if_nil?(rt.call_cfunc(addr, [loc])) {
            compile_push_stack_array(rt)
          }.else {
            rt.write(write_loc, rt.return_value)
          }
        }.else {
          rt.if_array?(loc) {
            # do nothing
          }.else {
            rt.if_nil?(rt.call_cfunc(addr, [loc])) {
              compile_push_stack_array(rt)
            }.else {
              rt.write(write_loc, rt.return_value)
            }
          }
        }
      end
    end

    # num is the number of elements we need to expand
    # flag is special
    def handle_expandarray num, flag
      raise NotImplementedError if flag != 0

      # handle_coercearray will try to coerce the stack's top value to an array
      # see vm_expandarray.  If the top of the stack isn't an array, it will
      # *allocate* an array on the machine's stack.  Then push that value on
      # the stack and tag it as an int by setting the lower bit to 1.  This
      # guarantees that the `compile_expandarray` runtime check will only ever
      # see an "int" which is actually a tagged array, or a real array.  If
      # it's tagged we just have to remove the tag and use it as an array.
      # Also if it's tagged we need to unwind rsp.

      handle_coercearray

      #sp_inc = num - 1 + (flag & 1 ? 1 : 0);

      req = CompileExpandArray.new(num, flag, @temp_stack.dup.freeze)
      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          rt.rb_funcall self, :compile_expandarray, [REG_CFP, req, rt.return_value]

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call
      req.deferred_entry = deferred.entry.to_i

      # attr rb_snum_t sp_inc = (rb_snum_t)num - 1 + (flag & 1 ? 1 : 0);
      @temp_stack.pop
      num.times { @temp_stack.push :unknown }

      with_runtime do |rt|
        rt.patchable_jump req.deferred_entry
      end
    end

    def handle_topn n
      with_runtime do |rt|
        peek = @temp_stack.peek(n)
        rt.push peek.loc, name: peek.name, type: peek.type
      end
    end

    # Call a C function at `func_loc` with `params`. Return value will be in RAX
    def call_cfunc func_loc, params, fisk = __
      raise NotImplementedError, "too many parameters" if params.length > 6
      raise "No function location" unless func_loc > 0

      fisk.push(fisk.rsp) # alignment
      params.each_with_index do |param, i|
        fisk.mov(Fisk::Registers::CALLER_SAVED[i], param)
      end
      fisk.mov(fisk.rax, fisk.uimm(func_loc))
        .call(fisk.rax)
      fisk.pop(fisk.rsp) # alignment
    end

    def rb; Internals; end

    def member_size struct, member
      TenderJIT.member_size(struct, member)
    end

    def break fisk = __
      fisk.int fisk.lit(3)
    end

    def print_str string
      Fisk.new { |__|
        __.jmp(__.absolute(@string_buffer.address))
      }.write_to(jit_buffer)

      fisk = Fisk.new
      fisk.jmp(fisk.label(:after_bytes))
      pos = nil
      fisk.lazy { |x| pos = x; string.bytes.each { |b| @string_buffer.putc b } }
      fisk.put_label(:after_bytes)
      fisk.mov fisk.rdi, fisk.uimm(2)
      fisk.lazy { |x|
        fisk.mov fisk.rsi, fisk.uimm(@string_buffer.memory + pos)
      }
      fisk.mov fisk.rdx, fisk.uimm(string.bytesize)
      fisk.mov fisk.rax, fisk.uimm(0x02000004)
      fisk.syscall
      fisk.jmp(fisk.absolute(jit_buffer.address.to_i))
      fisk.write_to(@string_buffer)
    end

    def with_runtime temp_stack = @temp_stack, alignment: 8
      rt = Runtime.new(Fisk.new, jit_buffer, temp_stack, alignment: alignment)
      yield rt
      rt.write!
    end

    if RbMethodDefinitionStruct.member("body").type.member?("optimize_type")
      def optimized_method_type mdef
        RbMethodDefinitionStruct.new(mdef).body.optimize_type
      end
    else
      def optimized_method_type mdef
        RbMethodDefinitionStruct.new(mdef).body.optimized.type
      end
    end

    if RClass.member("ptr")
      def class_ext klass
        RClass.ptr(klass)
      end
    else
      # RVARGC puts the class struct after the object
      def class_ext klass
        klass.to_i + RClass.byte_size
      end
    end

    def symbol_addr name
      Fiddle::Handle::DEFAULT[name]
    end

    def complex_method_exit req, patch_loc
      side_exit = req.make_exit(exits, "complex_method")
      patch_source_jump jit_buffer, at: patch_loc, to: side_exit
      side_exit
    end

    def simple_iseq? iseq
      iseq.body.param.flags.has_opt == 0 &&
        iseq.body.param.flags.has_rest == 0 &&
        iseq.body.param.flags.has_post == 0 &&
        iseq.body.param.flags.has_kw == 0 &&
        iseq.body.param.flags.has_kwrest == 0 &&
        iseq.body.param.flags.accepts_no_kwarg == 0 &&
        iseq.body.param.flags.has_block == 0
    end
  end
end
