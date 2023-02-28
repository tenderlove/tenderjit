# frozen_string_literal: true

require "jit_buffer"
require "tenderjit/fiddle_hacks"
require "tenderjit/mjit_hacks"
require "tenderjit/compiler/context"
require "tenderjit/c_funcs"
require "tenderjit/ir"
require "tenderjit/yarv"
require "fiddle/import"
require "hacks"
require "hatstone"
require "etc"

class TenderJIT
  C = RubyVM::MJIT.const_get(:C)
  INSNS = RubyVM::MJIT.const_get(:INSNS)

  extend Fiddle::Importer

  Stats = struct [
    "uint64_t compiled_methods",
    "uint64_t executed_methods",
    "uint64_t recompiles",
    "uint64_t exits",
  ]

  STATS = Stats.malloc(Fiddle::RUBY_FREE)

  def self.make_exit_function
    return
    jb = JITBuffer.new 4096
    ir = IR.new

    ec        = ir.param(0)
    cfp       = ir.param(1)
    sp_depth  = ir.param(2)
    jit_pc    = ir.param(3)

    # Increment the exit locations
    stats_location = ir.write(ir.var, STATS.to_i)
    stat = ir.load(stats_location, Stats.offsetof("exits"))
    inc = ir.add(stat, 0x1)
    ir.store(inc, stats_location, Stats.offsetof("exits"))

    iseq_offset = C.rb_iseq_t.offsetof(:body) +
      C.rb_iseq_constant_body.offsetof(:iseq_encoded)

    # flush the PC to the frame
    iseq = ir.load(cfp, C.rb_control_frame_t.offsetof(:iseq))
    body = ir.load(iseq, C.rb_iseq_t.offsetof(:body))
    pc   = ir.load(body, C.rb_iseq_constant_body.offsetof(:iseq_encoded))
    pc   = ir.add(pc, jit_pc)
    ir.store(pc, cfp, C.rb_control_frame_t.offsetof(:pc))

    # flush the SP to the frame
    sp = ir.load(cfp, C.rb_control_frame_t.offsetof(:sp))
    sp = ir.add(sp, sp_depth)
    ir.store(sp, cfp, C.rb_control_frame_t.offsetof(:sp))

    ir.return 1

    jb.writeable!
    ir.write_to jb
    jb.executable!
    jb
  end

  def self.disasm buf
    hs = case Util::PLATFORM
         when :arm64
           Hatstone.new(Hatstone::ARCH_ARM64, Hatstone::MODE_ARM)
         when :x86_64
           Hatstone.new(Hatstone::ARCH_X86, Hatstone::MODE_64)
         else
           raise "unknown platform"
         end

    # Now disassemble the instructions with Hatstone
    hs.disasm(buf[0, buf.pos], 0x0).each do |insn|
      puts "%#05x %s %s" % [insn.address, insn.mnemonic, insn.op_str]
    end
  end

  EXIT = make_exit_function

  def initialize
    @stats = STATS
    @stats.compiled_methods = 0
    @stats.executed_methods = 0
    @stats.recompiles       = 0
    @stats.exits            = 0
    @compiled_iseq_addrs    = []
  end

  # Entry point for manually compiling a method
  def compile method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    return unless rb_iseq # it's a C func

    iseq = method_to_iseq_t(rb_iseq)
    jit_addr = compile_iseq iseq
    iseq.body.jit_func = jit_addr
  end

  # Entry point for compiling an iseq, use this with MJIT
  def compile_iseq iseq
    @compiled_iseq_addrs << iseq.to_i
    Compiler.new.compile(iseq)
  end

  def uncompile_iseqs
    @compiled_iseq_addrs.each do |addr|
      C.rb_iseq_t.new(addr).body.jit_func = 0
    end
  end

  def uncompile method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    return unless rb_iseq # it's a C func

    iseq = method_to_iseq_t(rb_iseq)
    iseq.body.jit_func = 0
  end

  def method_to_iseq_t method
    addr = Fiddle.dlwrap(method)
    offset = Hacks::STRUCTS["RTypedData"]["data"][0]
    addr = Fiddle.read_ptr addr, offset
    C.rb_iseq_t.new addr
  end

  def compiled_methods
    @stats.compiled_methods
  end

  def executed_methods
    @stats.executed_methods
  end

  def exits
    @stats.exits
  end

  def enable!
    RubyVM::MJIT.resume
  end

  def disable!
    RubyVM::MJIT.pause(wait: false)
  end

  class Compiler
    def compile iseq
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

    def each_insn iseq
      @jit_pc = 0

      # Size of the ISEQ buffer
      iseq_size = iseq.body.iseq_size

      # ISEQ buffer
      iseq_buf = iseq.body.iseq_encoded

      yarv = YARV.new

      while @jit_pc < iseq_size
        insn = INSNS.fetch(C.rb_vm_insn_decode(iseq.body.iseq_encoded[@jit_pc]))
        operands = insn.opes.map.with_index { |operand,  i|
          case operand[:type]
          when "lindex_t" then iseq_buf[@jit_pc + i + 1]
          when "rb_num_t" then iseq_buf[@jit_pc + i + 1]
          when "OFFSET" then
            # OFFSET is signed
            Fiddle::Pointer.new(iseq_buf.to_i + ((@jit_pc + i + 1) * 8))[0, 8].unpack1("q")
          when "CALL_DATA" then C.rb_call_data.new(iseq_buf[@jit_pc + i + 1])
          when "VALUE" then Fiddle.dlunwrap(iseq_buf[@jit_pc + i + 1])
          else
            raise operand[:type]
          end
        }
        yarv.handle @jit_pc, insn, operands

        @jit_pc += insn.len
      end

      yarv.peephole_optimize!
      cfg = yarv.cfg
      cfg.number_instructions!

      #yield insn, operands
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

class << RubyVM::MJIT
  def compile iseq
    compiler = TenderJIT::Compiler.new
    compiler.compile iseq
  end
end
