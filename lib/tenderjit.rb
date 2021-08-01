require "tenderjit/ruby_internals"
require "tenderjit/fiddle_hacks"
require "tenderjit/exit_code"
require "tenderjit/jit_buffer_proxy"
require "fiddle/import"
require "fisk"
require "fisk/helpers"

class TenderJIT
  Internals = RubyInternals.get_internals

  # Struct layouts

  RBasic                = Internals.struct("RBasic")
  RTypedData            = Internals.struct("RTypedData")
  RbISeqT               = Internals.struct("rb_iseq_t")
  RbControlFrameStruct  = Internals.struct("rb_control_frame_struct")
  RbExecutionContextT   = Internals.struct("rb_execution_context_t")
  RbCallInfo            = Internals.struct("rb_callinfo")
  RbCallData            = Internals.struct("rb_call_data")
  RbCallableMethodEntryT = Internals.struct("rb_callable_method_entry_t")
  RbMethodDefinitionStruct = Internals.struct("rb_method_definition_struct")

  class RbCallInfo
    CI_EMBED_TAG_bits  = 1
    CI_EMBED_ARGC_bits = 15
    CI_EMBED_FLAG_bits = 16
    CI_EMBED_ID_bits   = 32
    CI_EMBED_ARGC_SHFT = CI_EMBED_TAG_bits
    CI_EMBED_ARGC_MASK = (1 << CI_EMBED_ARGC_bits) - 1
    CI_EMBED_FLAG_SHFT = CI_EMBED_TAG_bits + CI_EMBED_ARGC_bits
    CI_EMBED_FLAG_MASK = (1 << CI_EMBED_FLAG_bits) - 1
    CI_EMBED_ID_SHFT   = (CI_EMBED_TAG_bits + CI_EMBED_ARGC_bits + CI_EMBED_FLAG_bits)
    CI_EMBED_ID_MASK   = (1<<CI_EMBED_ID_bits) - 1

    def vm_ci_packed?
      to_i & 0x1 != 0
    end

    def vm_ci_flag
      if vm_ci_packed?
        (to_i >> CI_EMBED_FLAG_SHFT) & CI_EMBED_FLAG_MASK
      else
        flag
      end
    end

    def vm_ci_mid
      if vm_ci_packed?
        (to_i >> CI_EMBED_ID_SHFT) & CI_EMBED_ID_MASK
      else
        mid
      end
    end

    def vm_ci_argc
      if vm_ci_packed?
        (to_i >> CI_EMBED_ARGC_SHFT) & CI_EMBED_ARGC_MASK
      else
        argc
      end
    end
  end

  # Global Variables

  MJIT_CALL_P = Fiddle::Pointer.new(Internals.symbol_address("mjit_call_p"))
  MJIT_OPTIONS = Internals.struct("mjit_options").new(Internals.symbol_address("mjit_opts"))

  MJIT_OPTIONS.min_calls = 5
  MJIT_OPTIONS.wait = 0

  # Important Addresses

  VM_EXEC_CORE = Internals.symbol_address("vm_exec_core")

  # Important Constants

  Qtrue  = Internals.c "Qtrue"
  Qfalse = Internals.c "Qfalse"
  Qundef = Internals.c "Qundef"
  Qnil   = Internals.c "Qnil"

  T_FIXNUM = Internals.c "T_FIXNUM"
  T_ARRAY  = Internals.c "T_ARRAY"

  Internals.constants.each do |x|
    if /^(VM_CALL_.*)_bit$/ =~ x
      const_set $1, 1 << Internals.c(x)
    end
  end

  extend Fiddle::Importer

  Stats = struct [
    "uint64_t compiled_methods",
    "uint64_t executed_methods",
    "uint64_t exits",
  ]

  ExitStats = struct RubyVM::INSTRUCTION_NAMES.map { |n|
    "uint64_t #{n}"
  }

  attr_reader :jit_buffer, :exit_code

  # Returns true if the method has been compiled, otherwise false
  def self.compiled? method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    addr = RTypedData.new(Fiddle.dlwrap(rb_iseq)).data.to_i
    rb_iseq = RbISeqT.new(addr)
    rb_iseq.body.jit_func.to_i != 0
  end

  # Throw away any compiled code associated with the method
  def self.uncompile method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    addr = RTypedData.new(Fiddle.dlwrap(rb_iseq)).data.to_i
    rb_iseq = RbISeqT.new(addr)
    rb_iseq.body.jit_func = 0
    cov_ptr = Fiddle.dlunwrap(rb_iseq.body.variable.coverage)
    cov_ptr[2] = nil if cov_ptr
  end

  def initialize
    @stats = Stats.malloc(Fiddle::RUBY_FREE)
    @stats.compiled_methods = 0
    @stats.executed_methods = 0

    @exit_stats   = ExitStats.malloc(Fiddle::RUBY_FREE)
    @jit_buffer   = JITBufferProxy.new(Fisk::Helpers.jitbuffer(4096 * 4))

    @exit_code    = ExitCode.new @stats.to_i, @exit_stats.to_i
  end

  def exit_stats
    @exit_stats.to_h
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

  def compile method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    addr = method_to_iseq_t(rb_iseq)
    compile_iseq_t addr
  end

  def uncompile method
    self.class.uncompile method
  end

  def enable!
    MJIT_OPTIONS.on = 1
    MJIT_CALL_P[0] = 1
  end

  def disable!
    MJIT_OPTIONS.on = 0
    MJIT_CALL_P[0] = 0
  end

  def code_blocks iseq
    rb_iseq = RubyVM::InstructionSequence.of(iseq)
    addr = method_to_iseq_t(rb_iseq)
    ptr = RbISeqT.new(addr).body.variable.coverage
    if ptr == 0
      nil
    else
      # COVERAGE_INDEX_LINES is 0
      # COVERAGE_INDEX_BRANCHES is 1
      # 2 is unused so we'll use it. :D
      Fiddle.dlunwrap(ptr)[2]
    end
  end

  private

  REG_EC  = Fisk::Registers::RDI
  REG_CFP = Fisk::Registers::RSI
  REG_SP  = Fisk::Registers::RDX

  CodeBlock = Struct.new(:start, :finish)

  # rdi, rsi, rdx, rcx, r8 - r15
  #
  # Caller saved regs:
  #    rdi, rsi, rdx, rcx, r8 - r10

  def compile_iseq_t addr
    iseq_compiler = ISEQCompiler.new(@stats, self)
    iseq_compiler.compile addr
  end

  # Convert a method to an rb_iseq_t *address* (so, just the memory location
  # where the iseq exists)
  def method_to_iseq_t method
    RTypedData.new(Fiddle.dlwrap(method)).data.to_i
  end

  def self.member_size struct, member
    fiddle_type = struct.types[struct.members.index(member)]
    Fiddle::PackInfo::SIZE_MAP[fiddle_type]
  end
end

require "tenderjit/iseq_compiler"
