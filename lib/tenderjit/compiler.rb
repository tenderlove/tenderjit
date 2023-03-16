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
      @yarv_labels = {}
    end

    def yarv
      yarv_ir(@iseq)
    end

    def compile
      # method name
      # label = iseq.body.location.label

      STATS.compiled_methods += 1

      ir = IR.new

      ec  = ir.param(0)
      cfp = ir.param(1)

      buff = JITBuffer.new 4096
      ctx = Context.new(buff, ec, cfp, nil, nil)

      # Increment executed method count
      stats_location = ir.loadi(STATS.to_i)
      stat = ir.load(stats_location, ir.uimm(Stats.offsetof("executed_methods")))
      inc = ir.add(stat, ir.uimm(0x1))
      ir.store(inc, stats_location, ir.uimm(Stats.offsetof("executed_methods")))

      cfg = yarv.cfg
      translate_cfg cfg, ir, ctx
      asm = ir.assemble

      buff.writeable!
      asm.write_to buff

      if $DEBUG
        disasm buff
      end

      buff.executable!

      buff.to_i
    end

    private

    ##
    # Translate a CFG to IR
    def translate_cfg cfg, ir, context
      seen = {}
      worklist = [[cfg.first, context]]
      while work = worklist.pop
        yarv_block, context = *work
        # If we've seen the block before, it must be a joint point
        if seen[yarv_block]
          prev_context, insns = seen[yarv_block]
          phis = []

          # Add a phi function for stack items that differ
          prev_context.zip(context).reject { |left, right|
            left.reg == right.reg
          }.each { |existing, new|
            phis << IR::Phi.new(existing.reg, new.reg, ir.var)
          }

          # Make phi functions for locals
          yarv_block.phis.map(&:out).map(&:name).each { |name|
            existing = prev_context.get_local name
            new = context.get_local name
            phis << IR::Phi.new(existing, new, ir.var)
          }

          # Append all phis
          phis.each { |phi| insns._next.append phi }

          ## Walk past the phi nodes
          iter = insns._next._next
          while iter.phi?
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
        send insn.op, context, ir, insn
      end
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

    def put_label ctx, ir, insn
      ir.put_label yarv_label(ir, insn.opnds.first)
    end

    def putobject ctx, ir, insn
      obj = insn.opnds.first
      out = ir.loadi(Fiddle.dlwrap(obj))
      ctx.push Hacks.basic_type(obj), out
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

    def setlocal ctx, ir, insn
      local = insn.opnds
      ctx.set_local local.name, ctx.pop.reg
    end

    def getlocal ctx, ir, insn
      local = insn.opnds
      unless ctx.have_local?(local.name)
        # If the local hasn't been loaded yet, load it
        ep = ir.load(ctx.cfp, ir.uimm(C.rb_control_frame_t.offsetof(:ep)))
        index, _ = local.ops
        var = ir.load(ep, ir.imm(-index * Fiddle::SIZEOF_VOIDP))
        ctx.set_local local.name, var
      end
      ctx.push :unknown, ctx.get_local(local.name)
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
  end
end
