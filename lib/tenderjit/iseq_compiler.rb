# frozen_string_literal: true

require "tenderjit/temp_stack"
require "tenderjit/runtime"
require "tenderjit/jit_context"

class TenderJIT
  class ISEQCompiler
    LJUST = 22
    JMP_BYTES = 5

    SCRATCH_REGISTERS = [
      Fisk::Registers::R9,
      Fisk::Registers::R10,
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

    class CallCompileRequest < Struct.new(:call_info, :temp_stack, :current_pc, :next_pc, :deferred_entry)
      def make_exit exits, name = "opt_send_without_block"
        exits.make_exit(name, current_pc, temp_stack.size)
      end
    end

    IVarRequest = Struct.new(:id, :current_pc, :next_pc, :stack_loc, :deferred_entry)

    def compile_getinstancevariable recv, req, loc
      if rb.RB_SPECIAL_CONST_P(recv)
        raise NotImplementedError, "no ivar reads on non-heap objects"
      end

      type = rb.RB_BUILTIN_TYPE(recv)
      if type != T_OBJECT
        raise NotImplementedError, "no ivar reads on non objects #{type}"
      end

      klass        = CFuncs.rb_obj_class(recv)
      iv_index_tbl = RbClassExt.iv_index_tbl(RClass.ptr(klass)).to_i
      value        = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)

      if iv_index_tbl == 0 || 0 == CFuncs.rb_st_lookup(iv_index_tbl, req.id, value.ref)
        CFuncs.rb_ivar_set(recv, req.id, Qundef)
        iv_index_tbl = RbClassExt.iv_index_tbl(RClass.ptr(klass)).to_i
        CFuncs.rb_st_lookup(iv_index_tbl, req.id, value.ref)
      end

      ivar_idx = value.ptr.to_int

      code_start = jit_buffer.address
      patch_at   = loc - jit_buffer.memory.to_i
      return_loc = patch_at + 5

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
      loc = @temp_stack.pop

      addr = Fiddle::Handle::DEFAULT["rb_gvar_set"]
      with_runtime do |rt|
        if global_name == "$halt_at_runtime" && stack_val == true
          rt.break
        else
          rt.call_cfunc addr, [gid, loc]
        end
      end
    end

    def handle_dup
      last = @temp_stack.peek(0)
      with_runtime do |rt|
        rt.push last.loc, name: last.name, type: last.type
      end
    end

    def handle_concatstrings num
      loc = @temp_stack[num + 1]
      num.times { @temp_stack.pop }
      addr = Fiddle::Handle::DEFAULT["rb_str_concat_literals"]
      with_runtime do |rt|
        rt.with_ref(loc) do |reg|
          rt.call_cfunc addr, [num, reg]
        end
        rt.push rt.return_value, name: __method__, type: :string
      end
    end

    def compile_setinstancevariable recv, req, loc
      if rb.RB_SPECIAL_CONST_P(recv)
        raise NotImplementedError, "no ivar reads on non-heap objects"
      end

      type = rb.RB_BUILTIN_TYPE(recv)
      if type != T_OBJECT
        raise NotImplementedError, "no ivar reads on non objects #{type}"
      end

      klass        = CFuncs.rb_obj_class(recv).to_i
      iv_index_tbl = RClass.new(klass).ptr.iv_index_tbl.to_i

      value        = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)

      if iv_index_tbl == 0 || 0 == CFuncs.rb_st_lookup(iv_index_tbl, req.id, value.ref)
        CFuncs.rb_ivar_set(recv, req.id, Qundef)
        iv_index_tbl = RbClassExt.iv_index_tbl(RClass.ptr(klass))
        value        = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
        CFuncs.rb_st_lookup(Fiddle::Pointer.new(iv_index_tbl.to_i), req.id, value.ref)
      end

      ivar_idx = value.ptr.to_int

      code_start = jit_buffer.address
      return_loc = patch_source_jump jit_buffer, at: (loc - jit_buffer.memory.to_i),
                                                 to: code_start

      with_runtime do |rt|
        cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

        temp = rt.temp_var
        temp.write cfp_ptr.self

        self_ptr = rt.pointer(temp, type: RObject)

        # If the object class is the same, continue
        rt.if_eq(self_ptr.basic.klass, RBasic.klass(recv).to_i) {

          # If it's an embedded object, write to the embedded array
          rt.test_flags(self_ptr.basic.flags, ROBJECT_EMBED) {
            self_ptr.as.ary[ivar_idx] = rt.c_param(0)

          }.else { # Otherwise, the extended table
            temp.write self_ptr.as.heap.ivptr
            rt.pointer(temp)[ivar_idx] = rt.c_param(0)
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
      req = IVarRequest.new(id, current_pc, next_pc, @temp_stack.size)

      @compile_requests << Fiddle::Pinned.new(req)

      # `deferred_call` preserves the stack, so we can't pop from the temp
      # stack until after this method call
      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          rt.push_reg REG_BP
          rt.push_reg REG_BP
          rt.push_reg rt.c_param(0)
          rt.rb_funcall self, :compile_setinstancevariable, [cfp_ptr.self, req, rt.return_value]
          rt.pop_reg rt.c_param(0)
          rt.pop_reg REG_BP
          rt.pop_reg REG_BP

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      read_loc = @temp_stack.pop

      # jump back to the re-written jmp
      deferred.call

      req.deferred_entry = deferred.entry.to_i

      __.mov(__.rdi, read_loc)
      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred.entry.to_i))
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
      req = IVarRequest.new(id, current_pc, next_pc, @temp_stack.size)

      exit_addr = exits.make_exit("temporary_exit", current_pc, @temp_stack.size)

      write_loc = @temp_stack.push(:unknown)

      @compile_requests << Fiddle::Pinned.new(req)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

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

            rt.push_reg REG_BP
            rt.rb_funcall self, :compile_getinstancevariable, [cfp_ptr.self, req, rt.return_value]
            rt.pop_reg REG_BP

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

      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred.entry.to_i))
      __.mov(write_loc, __.rax)
    end

    def compile_opt_aref stack, req, patch_loc
      ci = req.call_info
      peek_recv = topn(stack, ci.vm_ci_argc).to_i

      if rb.RB_SPECIAL_CONST_P(peek_recv)
        raise NotImplementedError, "no aref reads on non-heap objects"
      end

      ## Compile the target method
      klass = RBasic.new(peek_recv).klass # FIXME: this only works on heap allocated objects

      entry_location = jit_buffer.address

      patch_loc = patch_loc - jit_buffer.memory.to_i

      jit_buffer.patch_jump at: patch_loc, to: entry_location

      param = req.temp_stack.peek(0).loc # param
      recv  = req.temp_stack.peek(1).loc # recv

      with_runtime do |rt|
        rt.set_c_param(0, recv)
        rt.set_c_param(1, param)
        _self = rt.pointer(rt.c_param(0), type: RObject)

        rt.if_eq(_self.basic.klass, klass) {
          klass = Fiddle.dlunwrap(klass)

          rt.flush_pc_and_sp req.next_pc, req.temp_stack.first.loc

          # We know it's an array at compile time
          if klass == ::Array
            rt.call_cfunc(rb.symbol_address("rb_ary_aref1"), [recv, param])

            # We know it's a hash at compile time
          elsif klass == ::Hash
            rt.call_cfunc(rb.symbol_address("rb_hash_aref"), [recv, param])

          else
            raise NotImplementedError
          end
        }.else {
          rt.patchable_jump req.deferred_entry
        }

        # patched a jmp and it is 5 bytes
        rt.jump jit_buffer.memory.to_i + patch_loc + 5
      end

      entry_location
    end

    def compile_opt_aset stack, req, patch_loc
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

          rt.flush_pc_and_sp req.next_pc, req.temp_stack.first.loc

          # We know it's an array at compile time
          if klass == ::Array
            raise
            rt.call_cfunc(rb.symbol_address("rb_ary_store"), [recv, param])

            # We know it's a hash at compile time
          elsif klass == ::Hash
            rt.call_cfunc(rb.symbol_address("rb_hash_aset"), [recv, param1, param2])

          else
            raise NotImplementedError
          end
        }.else {
          rt.patchable_jump req.deferred_entry
        }
        temp.release!

        # patched a jmp and it is 5 bytes
        rt.jump jit_buffer.memory.to_i + patch_loc + 5
      end

      entry_location
    end

    CompileOptAref = Struct.new(:call_info, :temp_stack, :current_pc, :next_pc, :deferred_entry)

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
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          rt.push_reg REG_BP # alignment
          rt.rb_funcall self, :compile_opt_aref, [cfp_ptr.sp, req, ctx.fisk.rax]
          rt.pop_reg REG_BP # alignment

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      req.deferred_entry = deferred.entry.to_i

      (argc + 1).times { @temp_stack.pop }

      #Jump in to the deferred compiler
      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred.entry))

      # The call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)
      __.mov(loc, __.rax)
    end

    def handle_opt_send_without_block call_data
      cd = RbCallData.new call_data
      ci = RbCallInfo.new cd.ci

      exit_addr = exits.make_exit("temporary_exit", current_pc, @temp_stack.size)

      # only handle simple methods
      #return unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE

      compile_request = CallCompileRequest.new
      compile_request.call_info = ci
      compile_request.temp_stack = @temp_stack.dup.freeze
      compile_request.current_pc = current_pc
      compile_request.next_pc = next_pc

      @compile_requests << Fiddle::Pinned.new(compile_request)

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

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

            rt.push_reg REG_BP
            rt.rb_funcall self, :compile_opt_send_without_block, [cfp_ptr.sp, compile_request, ctx.fisk.rax]
            rt.pop_reg REG_BP

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

      # Jump in to the deferred compiler
      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred.entry))

      (ci.vm_ci_argc + 1).times { @temp_stack.pop }

      # The method call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)
      __.pop(REG_BP)
      __.mov(loc, __.rax)
    end

    def topn stack, i
      Fiddle::Pointer.new(stack - (Fiddle::SIZEOF_VOIDP * (i + 1))).ptr
    end

    def vm_push_frame iseq, type, _self, specval, cref_or_me, pc, argv, local_size
      with_runtime do |rt|
        rt.with_ref(argv) do |sp|
          sp_ptr = rt.pointer sp
          ec_ptr = rt.pointer REG_EC, type: RbExecutionContextT
          cfp_ptr = rt.pointer REG_CFP, type: RbControlFrameStruct

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
          #     .__bp__     = sp
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
    end

    def compile_jump stack, req, patch_loc
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

    def compile_call_iseq iseq, compile_request, argc, iseq_ptr, recv, cme, return_loc
      # `vm_call_iseq_setup`
      param_size = iseq.body.param.size
      local_size = iseq.body.local_table_size
      opt_pc     = 0 # we don't handle optional parameters rn

      # `vm_call_iseq_setup_2` FIXME: we need to deal with TAILCALL
      # `vm_call_iseq_setup_normal` FIXME: we need to deal with TAILCALL

      temp_stack = compile_request.temp_stack

      # pop locals and recv off the stack
      #(ci.vm_ci_argc + 1).times { @temp_stack.pop }

      overflow_exit = compile_request.make_exit(exits)

      recv_loc = temp_stack.peek(argc).loc

      # Write next PC to CFP
      # Pop params and self from the stack
      with_runtime do |rt|
        rt.flush_pc_and_sp compile_request.next_pc, recv_loc
        rt.check_vm_stack_overflow compile_request.temp_stack, overflow_exit, local_size - param_size, iseq.body.stack_max
      end

      next_sp = temp_stack[argc - param_size - 1]

      # `vm_push_frame`
      vm_push_frame iseq_ptr,
        VM_FRAME_MAGIC_METHOD | VM_ENV_FLAG_LOCAL,
        recv_loc,
        0, #ci.block_handler,
        cme,
        iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
        next_sp,
        local_size - param_size

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

    def compile_call_cfunc iseq, compile_request, argc, iseq_ptr, recv, cme, return_loc
      cfunc = RbMethodDefinitionStruct.new(cme.def).body.cfunc
      param_size = if cfunc.argc == -1
                     argc
                   elsif cfunc.argc < 0
                     raise NotImplementedError
                   else
                     cfunc.argc
                   end

      frame_type = VM_FRAME_MAGIC_CFUNC | VM_FRAME_FLAG_CFRAME | VM_ENV_FLAG_LOCAL

      temp_stack = compile_request.temp_stack

      overflow_exit = compile_request.make_exit(exits)

      ## Pop params and self from the stack
      with_runtime do |rt|
        rt.flush_pc_and_sp compile_request.next_pc, temp_stack[argc]

        rt.check_vm_stack_overflow temp_stack, overflow_exit, 0, 0
      end

      recv_loc = temp_stack.peek(argc).loc
      next_sp = temp_stack[argc - param_size - 1]

      vm_push_frame(0,
                    frame_type,
                    temp_stack.peek(argc).loc,
                    0, #ci.block_handler,
                    cme,
                    0,
                    next_sp,
                    0)

      with_runtime do |rt|
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

    def compile_call_bmethod iseq, compile_request, argc, iseq_ptr, recv, cme, return_loc
      opt_pc     = 0 # we don't handle optional parameters rn
      proc_obj = RbMethodDefinitionStruct.new(cme.def).body.bmethod.proc
      proc = RData.new(proc_obj).data
      rb_block_t    = RbProcT.new(proc).block
      captured = rb_block_t.as.captured
      _self = recv
      type = VM_FRAME_MAGIC_BLOCK

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

      next_sp = temp_stack[argc - param_size - 1]

      vm_push_frame iseq.to_i,
        type | VM_FRAME_FLAG_BMETHOD,
        compile_request.temp_stack.peek(argc).loc,
        VM_GUARDED_PREV_EP(captured.ep),
        cme,
        iseq.body.iseq_encoded + (opt_pc * Fiddle::SIZEOF_VOIDP),
        next_sp,
        iseq.body.local_table_size - param_size

      with_runtime do |rt|
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

    def compile_opt_send_without_block stack, req, loc
      ci = req.call_info
      mid = ci.vm_ci_mid
      argc = ci.vm_ci_argc
      recv = topn(stack, argc).to_i

      patch_loc = loc - jit_buffer.memory.to_i

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

      # If we find an iseq method, compile it, even if we don't enter.
      if method_definition.type == VM_METHOD_TYPE_ISEQ
        iseq_ptr = RbMethodDefinitionStruct.new(cme.def).body.iseq.iseqptr.to_i
        iseq = RbISeqT.new(iseq_ptr)
        @jit.compile_iseq_t iseq_ptr
      end

      # If we find a bmethod method, compile the block iseq.
      if method_definition.type == VM_METHOD_TYPE_BMETHOD
        proc_obj = RbMethodDefinitionStruct.new(cme.def).body.bmethod.proc
        proc = RData.new(proc_obj).data
        rb_block_t    = RbProcT.new(proc).block
        if rb_block_t.type != rb.c("block_type_iseq")
          raise NotImplementedError
        end

        iseq_ptr = rb_block_t.as.captured.code.iseq

        iseq = RbISeqT.new(iseq_ptr)

        @jit.compile_iseq_t iseq_ptr
      end

      # Bail on any method calls that aren't "simple".  Not handling *args,
      # kwargs, etc right now
      #if ci.vm_ci_flag & VM_CALL_ARGS_SPLAT > 0
      unless (ci.vm_ci_flag & VM_CALL_ARGS_SIMPLE) == VM_CALL_ARGS_SIMPLE
        side_exit = req.make_exit(exits, "complex_method")
        patch_source_jump jit_buffer, at: patch_loc, to: side_exit
        return side_exit
      end

      method_entry_addr = jit_buffer.address
      return_loc = patch_loc + JMP_BYTES

      # Lift the address up to a Ruby object.  `recv` is the address of the
      # Ruby object, not the object itself.  Lets get the object itself so we
      # can perform tests on it.
      rb_recv = Fiddle.dlunwrap recv

      with_runtime do |rt|
        temp_stack = req.temp_stack
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
      when VM_METHOD_TYPE_CFUNC
        compile_call_cfunc iseq, req, argc, iseq_ptr, recv, cme, return_loc
      when VM_METHOD_TYPE_ISEQ
        compile_call_iseq iseq, req, argc, iseq_ptr, recv, cme, return_loc
      when VM_METHOD_TYPE_BMETHOD
        compile_call_bmethod iseq, req, argc, iseq_ptr, recv, cme, return_loc
      else
        side_exit = req.make_exit(exits, "unknown_method_type")
        patch_source_jump jit_buffer, at: patch_loc, to: side_exit
        return side_exit
      end

      patch_source_jump jit_buffer, at: patch_loc, to: method_entry_addr

      method_entry_addr
    end

    def handle_nop; end

    def handle_newarray num
      address = Fiddle::Handle::DEFAULT["rb_ec_ary_new_from_values"]

      with_runtime do |rt|
        rt.push_reg REG_BP

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
          ret = rt.call_cfunc_without_alignment(address, [REG_EC, num, ref])
          rt.push ret, name: "array"
        end

        rt.pop_reg REG_BP # magic
      end
    end

    def handle_duparray ary
      write_loc = @temp_stack.push(:object, type: T_ARRAY)

      __.push REG_BP
      call_cfunc rb.symbol_address("rb_ary_resurrect"), [__.uimm(ary)]
      __.pop REG_BP

      __.mov write_loc, __.rax
    end

    def handle_duphash hash
      write_loc = @temp_stack.push(:object, type: RUBY_T_HASH)

      __.push REG_BP
      call_cfunc rb.symbol_address("rb_hash_resurrect"), [__.uimm(hash)]
      __.pop REG_BP

      __.mov write_loc, __.rax
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

      deferred = @jit.deferred_call(@temp_stack) do |ctx|
        ctx.with_runtime do |rt|
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          rt.push_reg REG_BP
          rt.rb_funcall self, :compile_jump, [cfp_ptr.sp, patch_request, rt.return_value]
          rt.pop_reg REG_BP

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      flush

      deferred.call

        #__.int(__.lit(3))
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
            cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

            rt.push_reg REG_BP
            rt.rb_funcall self, :compile_jump, [cfp_ptr.sp, patch, ctx.fisk.rax]
            rt.pop_reg REG_BP

            rt.NUM2INT(rt.return_value)

            rt.jump rt.return_value
          end
        end

        req.call
        req
      end

      if target_jump_block
        jit_buffer.write_jump to: target_jump_block.start_address,
                              type: :jnz
      else
        # Jump if value is true
        __.lea(__.rax, __.rip)
        __.jnz(__.absolute(deferred_true.entry))
      end

      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred_false.entry))

      :stop
    end

    class HandleOptGetinlinecache < Struct.new(:jump_idx, :jump_type, :temp_stack, :ic, :current_pc)
    end

    def compile_opt_getinlinecache stack, req, patch_loc
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
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          rt.push_reg REG_BP
          rt.rb_funcall self, :compile_opt_getinlinecache, [cfp_ptr.sp, patch_request, ctx.fisk.rax]
          rt.pop_reg REG_BP

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
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          rt.push_reg REG_BP
          rt.rb_funcall self, :compile_jump, [cfp_ptr.sp, patch_request, ctx.fisk.rax]
          rt.pop_reg REG_BP

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred.entry.to_i))

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
      loc = @temp_stack.push(:self)

      reg_self = __.register "self"

      # Get self from the CFP
      __.mov(reg_self, __.m64(REG_CFP, RbControlFrameStruct.offsetof("self")))
        .mov(loc, reg_self)
    end

    def handle_putobject literal
      loc = if rb.RB_FIXNUM_P(literal)
              @temp_stack.push(:literal, type: T_FIXNUM)
            elsif literal == Qtrue
              @temp_stack.push(:literal, type: true)
            elsif literal == Qfalse
              @temp_stack.push(:literal, type: false)
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
      __.add(REG_CFP, __.uimm(RbControlFrameStruct.byte_size))

      # Write the frame pointer back to the ec
      __.mov __.m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP
      __.ret
      :stop
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
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)

          rt.push_reg REG_BP # alignment
          rt.rb_funcall self, :compile_opt_aset, [cfp_ptr.sp, req, rt.return_value]
          rt.pop_reg REG_BP # alignment

          rt.NUM2INT(rt.return_value)

          rt.jump rt.return_value
        end
      end

      deferred.call

      req.deferred_entry = deferred.entry.to_i

      (argc + 1).times { @temp_stack.pop }

      #Jump in to the deferred compiler
      __.lea(__.rax, __.rip)
      __.jmp(__.absolute(deferred.entry))

      # The call will return here, and its return value will be in RAX
      loc = @temp_stack.push(:unknown)
      __.mov(loc, __.rax)
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

    def handle_tostring
      address = Fiddle::Handle::DEFAULT["rb_obj_as_string_result"]
      val = @temp_stack.pop
      str = @temp_stack.pop

      with_runtime do |rt|
        rt.push_reg REG_BP
        new_string_address = rt.call_cfunc_without_alignment(address, [val, str])
        rt.push new_string_address, name: "string"
        rt.pop_reg REG_BP
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

    def VM_GUARDED_PREV_EP ep
      ep.to_i | 0x01
    end

    def with_runtime
      rt = Runtime.new(Fisk.new, jit_buffer, @temp_stack)
      yield rt
      rt.write!
    end
  end
end
