# frozen_string_literal: true

require "tenderjit/fiddle_hacks"
require "tenderjit/mjit_hacks"
require "tenderjit/c_funcs"
require "tenderjit/ir"
require "tenderjit/compiler"
require "fiddle/import"
require "hacks"
require "hatstone"
require "etc"

class TenderJIT
  C = RubyVM::RJIT.const_get(:C)
  INSNS = RubyVM::RJIT.const_get(:INSNS)

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
    compiler = Compiler.for_method method
    return unless compiler

    jit_addr = compiler.compile
    @compiled_iseq_addrs << compiler.iseq.to_i
    compiler.iseq.body.jit_func = jit_addr
  end

  def uncompile_iseqs
    @compiled_iseq_addrs.each do |addr|
      C.rb_iseq_t.new(addr).body.jit_func = 0
    end
  end

  def uncompile method
    Compiler.uncompile method
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
    RubyVM::RJIT.resume
  end

  def disable!
    #RubyVM::RJIT.pause
  end
end

class << RubyVM::RJIT
  def compile iseq
    compiler = TenderJIT::Compiler.new
    compiler.compile iseq
  end
end
