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
      iseq.body.jit_func = 0
    end

    def self.method_to_iseq_t method
      addr = Fiddle.dlwrap(method)
      offset = Hacks::STRUCTS["RTypedData"]["data"][0]
      addr = Fiddle.read_ptr addr, offset
      C.rb_iseq_t.new addr
    end

    attr_reader :iseq

    def initialize iseq
      @iseq = iseq
    end

    def yarv
      yarv_ir(@iseq)
    end

    def compile
      # method name
      label = iseq.body.location.label

      STATS.compiled_methods += 1

      ir = IR.new

      ec  = ir.param(0)
      cfp = ir.param(1)
      sp  = ir.param(2)
      ep  = ir.param(3)

      buff = JITBuffer.new 4096
      ctx = Context.new(buff, ec, cfp, sp, ep)

      # Load the ep and the sp because we'll probably use them
      ir.write(sp, ir.load(cfp, ir.uimm(C.rb_control_frame_t.offsetof(:sp))))
      ir.write(ep, ir.load(cfp, ir.uimm(C.rb_control_frame_t.offsetof(:ep))))

      # Increment executed method count
      stats_location = ir.write(ir.var, ir.uimm(STATS.to_i))
      stat = ir.load(stats_location, ir.uimm(Stats.offsetof("executed_methods")))
      inc = ir.add(stat, ir.uimm(0x1))
      ir.store(inc, stats_location, ir.uimm(Stats.offsetof("executed_methods")))

      each_insn(iseq) do |insn, operands|
        send insn.name, ctx, ir, *operands
      end

      buff.writeable!
      ir.write_to buff
      buff.executable!

      buff.to_i
    end

    private

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

      stack_size = 0

      while jit_pc < iseq_size
        insn = INSNS.fetch(C.rb_vm_insn_decode(iseq.body.iseq_encoded[jit_pc]))
        operands = insn.opes.map.with_index { |operand,  i|
          case operand[:type]
          when "lindex_t" then iseq_buf[jit_pc + i + 1]
          when "rb_num_t" then iseq_buf[jit_pc + i + 1]
          when "OFFSET" then
            # OFFSET is signed
            Fiddle::Pointer.new(iseq_buf.to_i + ((jit_pc + i + 1) * 8))[0, 8].unpack1("q")
          when "CALL_DATA" then C.rb_call_data.new(iseq_buf[jit_pc + i + 1])
          when "VALUE" then Fiddle.dlunwrap(iseq_buf[jit_pc + i + 1])
          else
            raise operand[:type]
          end
        }
        yarv.handle jit_pc, insn, operands

        jit_pc += insn.len
      end

      yarv.peephole_optimize!

      yarv
    end

    def putobject ctx, ir, obj
      out = ir.write(ir.var, Fiddle.dlwrap(obj))
      ir.store(out, ctx.sp, ir.uimm(ctx.stack_depth_b))
      ctx.push Hacks.basic_type(obj), out
    end

    def putobject_INT2FIX_1_ ctx, ir
      putobject ctx, ir, 1
    end

    def putobject_INT2FIX_0_ ctx, ir
      putobject ctx, ir, 0
    end

    def opt_lt ctx, ir, cd
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      unless l_type.fixnum? && r_type.fixnum?
        # Generate an exit
        generate_exit ctx, ctx.stack_depth_b, ir, exit_label
      end

      right = ir.load(ctx.sp, r_type.depth_b)

      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = ir.load(ctx.sp, l_type.depth_b)

      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      ir.cmp left, right
      out = ir.csel_lt ir.write(ir.var, Fiddle::Qtrue), ir.write(ir.var, Fiddle::Qfalse)

      ctx.pop
      ctx.pop
      ir.store out, ctx.sp, ctx.push(Hacks.basic_type(true), out).depth_b
    end

    def opt_plus ctx, ir, cd
      r_type = ctx.peek(0)
      l_type = ctx.peek(1)

      exit_label = ir.label(:exit)

      # Generate an exit
      generate_exit ctx, ctx.stack_depth_b, ir, exit_label

      right = ir.load(ctx.sp, r_type.depth_b)

      # Only test the type at runtime if we don't know for sure
      guard_fixnum ir, right, exit_label unless r_type.fixnum?

      left = ir.load(ctx.sp, l_type.depth_b)

      # Only test the type at runtime if we don't know for sure
      guard_fixnum ir, left, exit_label unless l_type.fixnum?

      # subtract the mask from one side
      right = ir.sub right, ir.uimm(0x1)

      # Add them
      out = ir.add(left, right)
      ir.jo exit_label

      ctx.pop
      ctx.pop
      ir.store out, ctx.sp, ctx.push(:T_FIXNUM, out).depth_b
    end

    def getlocal_WC_0 ctx, ir, index
      local = ir.load(ctx.ep, ir.imm(-index * Fiddle::SIZEOF_VOIDP))
      ir.store(local, ctx.sp, ir.uimm(ctx.stack_depth_b))
      ctx.push :unknown, local
    end

    def leave ctx, ir
      ctx.pop
      local = ir.load(ctx.sp, ir.imm(ctx.stack_depth_b))

      prev_frame = ir.add ctx.cfp, ir.uimm(C.rb_control_frame_t.sizeof)
      ir.store(prev_frame, ctx.ec, ir.uimm(C.rb_execution_context_t.offsetof(:cfp)))

      ir.return local
    end

    def disasm buf
      TenderJIT.disasm buf
    end

    def generate_exit ctx, depth, ir, label
      pass = ir.label :pass
      ir.jmp pass
      ir.put_label label
      ir.set_param ctx.ec
      ir.set_param ctx.cfp
      ir.set_param depth
      ir.set_param @jit_pc * Fiddle::SIZEOF_VOIDP
      ir.call ir.write(ir.var, EXIT.to_i), 4
      ir.return Fiddle::Qundef
      ir.put_label pass
    end

    def guard_fixnum ir, reg, exit_label
      continue = ir.label :continue
      ir.tbnz reg, 0, continue # continue if bottom bit is 1
      ir.jmp exit_label
      ir.put_label continue
    end
  end
end
