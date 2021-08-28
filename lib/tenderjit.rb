# frozen_string_literal: true

require "tenderjit/ruby_internals"
require "tenderjit/fiddle_hacks"
require "tenderjit/exit_code"
require "tenderjit/deferred_compilations"
require "tenderjit/c_funcs"
require "fiddle/import"
require "fisk"
require "fisk/helpers"
require "etc"

class TenderJIT
  REG_EC  = Fisk::Registers::R13
  REG_CFP = Fisk::Registers::R14
  REG_BP  = Fisk::Registers::R15

  Internals = RubyInternals.get_internals

  # Struct layouts

  RBasic                = Internals.struct("RBasic")

  class RBasic
    %w{ flags klass }.each do |item|
      offset = offsetof(item)

      define_singleton_method item do |address|
        Fiddle.read_ptr address, offset
      end
    end
  end
  RClass                = Internals.struct("RClass")
  RObject               = Internals.struct("RObject")
  RTypedData            = Internals.struct("RTypedData")

  class RTypedData
    %w{ data }.each do |item|
      offset = offsetof(item)

      define_singleton_method item do |address|
        Fiddle.read_ptr address, offset
      end
    end
  end

  RData                 = Internals.struct("RData")
  RbISeqT               = Internals.struct("rb_iseq_t")
  RbProcT               = Internals.struct("rb_proc_t")
  RbControlFrameStruct  = Internals.struct("rb_control_frame_struct")
  RbExecutionContextT   = Internals.struct("rb_execution_context_t")
  RbCallInfo            = Internals.struct("rb_callinfo")
  RbCallData            = Internals.struct("rb_call_data")
  RbCallableMethodEntryT = Internals.struct("rb_callable_method_entry_t")
  RbMethodDefinitionStruct = Internals.struct("rb_method_definition_struct")
  RbIseqConstantBody = Internals.struct("rb_iseq_constant_body")
  IseqInlineConstantCacheEntry = Internals.struct("iseq_inline_constant_cache_entry")
  IseqInlineConstantCache = Internals.struct("iseq_inline_constant_cache")

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

    def is_args_kw_splat?
      (vm_ci_flag & VM_CALL_KWARG) != 0
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
  T_NIL    = Internals.c "T_NIL"
  T_CLASS  = Internals.c "T_CLASS"
  T_OBJECT  = Internals.c "T_OBJECT"
  ROBJECT_EMBED = Internals.c("ROBJECT_EMBED")

  Internals.constants.each do |x|
    case x
    when /^(VM_CALL_.*)_bit$/
      const_set $1, 1 << Internals.c(x)
    when /^VM_(?:FRAME|ENV|METHOD).*$/
      const_set x, Internals.c(x)
    when /^RUBY_.*$/
      const_set x, Internals.c(x)
    end
  end

  ALL_TYPES = [
    RUBY_T_NONE,
    RUBY_T_OBJECT,
    RUBY_T_CLASS,
    RUBY_T_MODULE,
    RUBY_T_FLOAT,
    RUBY_T_STRING,
    RUBY_T_REGEXP,
    RUBY_T_ARRAY,
    RUBY_T_HASH,
    RUBY_T_STRUCT,
    RUBY_T_BIGNUM,
    RUBY_T_FILE,
    RUBY_T_DATA,
    RUBY_T_MATCH,
    RUBY_T_COMPLEX,
    RUBY_T_RATIONAL,
    RUBY_T_NIL,
    RUBY_T_TRUE,
    RUBY_T_FALSE,
    RUBY_T_SYMBOL,
    RUBY_T_FIXNUM,
    RUBY_T_UNDEF,
    RUBY_T_IMEMO,
    RUBY_T_NODE,
    RUBY_T_ICLASS,
    RUBY_T_ZOMBIE,
    RUBY_T_MOVED,
  ]

  HEAP_TYPES = [
    RUBY_T_NONE,
    RUBY_T_OBJECT,
    RUBY_T_CLASS,
    RUBY_T_MODULE,
    RUBY_T_FLOAT,
    RUBY_T_STRING,
    RUBY_T_REGEXP,
    RUBY_T_ARRAY,
    RUBY_T_HASH,
    RUBY_T_STRUCT,
    RUBY_T_BIGNUM,
    RUBY_T_FILE,
    RUBY_T_DATA,
    RUBY_T_MATCH,
    RUBY_T_COMPLEX,
    RUBY_T_RATIONAL,
    #RUBY_T_NIL,
    #RUBY_T_TRUE,
    #RUBY_T_FALSE,
    #RUBY_T_SYMBOL,
    #RUBY_T_FIXNUM,
    #RUBY_T_UNDEF,
    RUBY_T_IMEMO,
    RUBY_T_NODE,
    RUBY_T_ICLASS,
    RUBY_T_ZOMBIE,
    RUBY_T_MOVED,
  ]

  SPECIAL_TYPES = ALL_TYPES - HEAP_TYPES

  VM_ENV_DATA_INDEX_ME_CREF    = -2 # /* ep[-2] */
  VM_ENV_DATA_INDEX_SPECVAL    = -1 # /* ep[-1] */
  VM_ENV_DATA_INDEX_FLAGS      =  0 # /* ep[ 0] */
  VM_ENV_DATA_INDEX_ENV        =  1 # /* ep[ 1] */

  extend Fiddle::Importer

  Stats = struct [
    "uint64_t compiled_methods",
    "uint64_t executed_methods",
    "uint64_t recompiles",
    "uint64_t exits",
  ]

  ExitStats = struct RubyVM::INSTRUCTION_NAMES.map { |n|
    "uint64_t #{n}"
  }

  attr_reader :jit_buffer, :exit_code

  # Returns true if the method has been compiled, otherwise false
  def self.compiled? method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    return false unless rb_iseq
    addr = RTypedData.new(Fiddle.dlwrap(rb_iseq)).data.to_i
    rb_iseq = RbISeqT.new(addr)
    rb_iseq.body.jit_func.to_i != 0
  end

  # Throw away any compiled code associated with the method
  def self.uncompile method
    rb_iseq = RubyVM::InstructionSequence.of(method)
    return false unless rb_iseq
    addr = RTypedData.new(Fiddle.dlwrap(rb_iseq)).data.to_i
    rb_iseq = RbISeqT.new(addr)
    rb_iseq.body.jit_func = 0
    cov_ptr = Fiddle.dlunwrap(rb_iseq.body.variable.coverage)
    cov_ptr[2] = nil if cov_ptr
  end

  SIZE = 4096 * (4 * 3)

  CACHE_BUSTERS = Fisk::Helpers.jitbuffer(4096)

  def self.print_str fisk, string, jit_buffer
    fisk.jmp(fisk.label(:after_bytes))
    pos = nil
    fisk.lazy { |x| pos = x; string.bytes.each { |b| jit_buffer.putc b } }
    fisk.put_label(:after_bytes)
    fisk.mov fisk.rdi, fisk.uimm(1)
    fisk.lazy { |x|
      fisk.mov fisk.rsi, fisk.uimm(jit_buffer.memory + pos)
    }
    fisk.mov fisk.rdx, fisk.uimm(string.bytesize)
    fisk.mov fisk.rax, fisk.uimm(0x02000004)
    fisk.syscall
  end

  # This will keep a list of ISeqs that are interested in
  # `rb_clear_constant_cache` getting called
  CONST_WATCHERS = Fiddle.malloc(4096)

  STATS = Stats.malloc(Fiddle::RUBY_FREE)

  # Any time `ruby_vm_global_constant_state` changes, we need to invalidate
  # any JIT code that cares about that value.  This method monkey patches
  # `rb_clear_constant_cache` because it is the only thing that mutates the
  # `ruby_vm_global_constant_state` global.
  def self.install_const_state_change_handler interpreter_call_prelude
    cov_offset = RbIseqConstantBody.offsetof("variable.coverage")

    interpreter_call_prelude.each_byte { |byte| CACHE_BUSTERS.putc byte }

    fisk = Fisk.new { |__|
      __.with_register do |tmp1|
        # Book keeping. Count the number of recompiles
        __.mov(tmp1, __.uimm(STATS.to_i))
          .inc(__.m64(tmp1, Stats.offsetof("recompiles")))

        __.mov(REG_BP, __.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
          .lea(tmp1, __.m(REG_BP, 0))
          .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), tmp1)

        __.mov(tmp1, __.m64(REG_CFP, RbControlFrameStruct.offsetof("iseq")))
          .mov(__.rdi, __.m64(tmp1, RbISeqT.offsetof("body")))
          .mov(__.rdi, __.m64(__.rdi, cov_offset))
          .mov(__.rsi, __.uimm(2))
          .mov(__.rax, __.uimm(Fiddle::Handle::DEFAULT["rb_ary_entry"]))
          .call(__.rax) # After this, rax should have the iseq compiler
          .mov(__.rdi, __.rax)
          .mov(__.rsi, __.uimm(CFuncs.rb_intern("recompile!")))
          .mov(__.rdx, __.uimm(0))
          .mov(__.rax, __.uimm(Fiddle::Handle::DEFAULT["rb_funcall"]))
          .call(__.rax)
          .mov(__.rax, __.uimm(Qundef))
          .ret
      end
    }
    fisk.assign_registers([fisk.r9, fisk.r10], local: true)

    pos = CACHE_BUSTERS.pos
    fisk.write_to(CACHE_BUSTERS)
    jump_loc = CACHE_BUSTERS.memory.to_i + pos

    # This function will invalidate JIT code on any iseq that needs to be
    # invalidated when ruby_vm_global_constant_state changes.
    fisk = Fisk.new { |__|
      __.push(__.rbp)
        .mov(__.rbp, __.rsp)

      # Increment the global constant state
      __.mov(__.rax, __.uimm(Fiddle::Handle::DEFAULT["ruby_vm_global_constant_state"]))
        .inc(__.m64(__.rax))

      __.with_register("ary ptr") do |ary_ptr|
        __.with_register("int i") do |i|
          __.with_register("int x = *ptr") do |x|
            __.with_register("jump") do |jump|
            __.mov(ary_ptr, __.uimm(CONST_WATCHERS.to_i))
              .xor(i, i)
              .xor(__.rax, __.rax)
              .mov(x, __.m64(ary_ptr))
              .put_label(:loop)
              .add(ary_ptr, __.uimm(Fiddle::SIZEOF_VOIDP))
              .cmp(i, x)
              .jge(__.label(:done))
              .mov(__.rax, __.m64(ary_ptr))
              .mov(jump, __.uimm(jump_loc))
              .test(__.rax, __.rax)
              .jz(__.label(:body_is_null))
              .mov(__.m64(__.rax, RbIseqConstantBody.offsetof("jit_func")), jump) # Clear JIT ptr here
              .mov(__.m64(ary_ptr), __.uimm(0))
              .put_label(:body_is_null)
              .inc(i)
              .jmp(__.label(:loop))
              .put_label(:done)
            end
          end
        end
      end

      __.pop(__.rbp)
        .ret
    }

    buffer_pos = CACHE_BUSTERS.pos
    fisk.assign_registers(Fisk::Registers::CALLER_SAVED, local: true)
    fisk.write_to(CACHE_BUSTERS)

    monkey_patch = StringIO.new

    Fisk.new { |__|
      __.mov(__.rax, __.uimm(CACHE_BUSTERS.memory.to_i + buffer_pos))
        .jmp(__.rax)
    }.write_to(monkey_patch)

    monkey_patch = monkey_patch.string

    addr = Fiddle::Handle::DEFAULT["rb_clear_constant_cache"]

    func_memory = Fiddle::Pointer.new addr
    page_size = Etc.sysconf(Etc::SC_PAGE_SIZE)
    page_head = addr & ~(0xFFF)
    if CFuncs.mprotect(page_head, page_size, 0x1 | 0x4 | 0x2) != 0
      raise NotImplementedError, "couldn't make function writeable"
    end
    func_memory[0, monkey_patch.bytesize] = monkey_patch
  end

  def self.interpreter_call
    buf = StringIO.new(''.b)

    Fisk.new { |__|
      __.push(REG_EC) # Push "don't care" reg for alignment
        .push(REG_EC)
        .push(REG_CFP)
        .push(REG_BP)
        .lea(__.rax, __.rip(__.label(:return)))
        .push(__.rax)
        .jmp(__.label(:skip_return))
        .put_label(:return)
        .pop(REG_BP)
        .pop(REG_CFP)
        .pop(REG_EC)
        .pop(REG_EC)
        .ret

      __.put_label(:skip_return)
      __.mov(REG_EC, __.rdi)
        .mov(REG_CFP, __.rsi)
    }.write_to(buf)

    buf.string
  end

  INTERPRETER_CALL = interpreter_call.freeze

  install_const_state_change_handler(INTERPRETER_CALL)

  attr_reader :stats
  attr_reader :interpreter_call

  def initialize
    @stats = STATS
    @stats.compiled_methods = 0
    @stats.executed_methods = 0
    @stats.recompiles       = 0
    @stats.exits            = 0

    @exit_stats   = ExitStats.malloc(Fiddle::RUBY_FREE)

    memory        = Fisk::Helpers.mmap_jit(SIZE)
    CFuncs.memset(memory, 0xCC, SIZE)
    @jit_buffer   = Fisk::Helpers::JITBuffer.new memory, SIZE / 3

    @interpreter_call = INTERPRETER_CALL

    memory += SIZE / 3
    @deferred_calls = DeferredCompilations.new(Fisk::Helpers::JITBuffer.new(memory, SIZE / 3))

    memory += SIZE / 3
    exit_buffer   = Fisk::Helpers::JITBuffer.new(memory, SIZE / 3)
    @exit_code    = ExitCode.new exit_buffer, @stats.to_i, @exit_stats.to_i
  end

  def deferred_call temp_stack, &block
    @deferred_calls.deferred_call(temp_stack, &block)
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

  def recompiles
    @stats.recompiles
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
      Fiddle.dlunwrap(ptr)[2]&.blocks
    end
  end

  # rdi, rsi, rdx, rcx, r8 - r15
  #
  # Caller saved regs:
  #    rdi, rsi, rdx, rcx, r8 - r10

  def compile_iseq_t addr
    body = RbISeqT.new(addr).body
    ptr = body.variable.coverage

    ary = nil
    if ptr == 0
      ary = []
      body.variable.coverage = Fiddle.dlwrap(ary)
    else
      ary = Fiddle.dlunwrap(ptr)
    end

    # COVERAGE_INDEX_LINES is 0
    # COVERAGE_INDEX_BRANCHES is 1
    # 2 is unused so we'll use it. :D

    # Cache the iseq compiler for this iseq inside the code coverage array.
    if ary[2]
      iseq_compiler = ary[2]
    else
      iseq_compiler = ISEQCompiler.new(self, addr)
      ary[2] = iseq_compiler
    end

    iseq_compiler.compile
    iseq_compiler
  end

  private

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
