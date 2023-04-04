# frozen_string_literal: true

require "tenderjit/fiddle_hacks"
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
    hs.disasm(buf[0, buf.pos], buf.to_i).each do |insn|
      puts "%#05x %s %s" % [insn.address, insn.mnemonic, insn.op_str]
    end
  end

  def initialize
    @stats = STATS
    @stats.compiled_methods = 0
    @stats.executed_methods = 0
    @stats.recompiles       = 0
    @stats.exits            = 0
    @compiled_iseq_addrs    = []
  end

  # Entry point for manually compiling a method
  def compile iseq, cfp
    return if iseq.body.jit_func != 0

    compiler = TenderJIT::Compiler.new iseq
    jit_addr = compiler.compile cfp

    @compiled_iseq_addrs << compiler.iseq.to_i
    iseq.body.jit_func = jit_addr
  end

  def uncompile_iseqs
    @compiled_iseq_addrs.each do |addr|
      C.rb_iseq_t.new(addr).body.jit_func = 0
      C.rb_iseq_t.new(addr).body.variable.coverage = 0
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
