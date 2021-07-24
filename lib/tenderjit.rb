require "tenderjit/ruby_internals"
require "tenderjit/fiddle_hacks"
require "tenderjit/exit_code"
require "fiddle/import"
require "fisk"

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

  T_FIXNUM = Internals.c "T_FIXNUM"

  Internals.constants.each do |x|
    if /^(VM_CALL_.*)_bit$/ =~ x
      p $1 => Internals.c(x)
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

  class TempStack
    Item = Struct.new(:name, :type, :loc)

    def initialize
      @stack = []
      @sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")
    end

    # Returns the info stored for stack location +idx+
    def peek idx
      @stack.fetch idx
    end

    # Push a value on the temp stack. Returns the memory location where
    # to write the actual value in machine code.
    def push name, type: nil
      m = Fisk::M64.new(REG_SP, @stack.length * @sizeof_sp)
      @stack.push Item.new(name, type, m)
      m
    end

    # Pop a value from the temp stack. Returns the memory location where the
    # value should be read in machine code.
    def pop
      @stack.pop.loc
    end

    def size
      @stack.size
    end
  end

  def initialize
    @stats = Stats.malloc(Fiddle::RUBY_FREE)
    @stats.compiled_methods = 0
    @stats.executed_methods = 0

    @exit_stats   = ExitStats.malloc(Fiddle::RUBY_FREE)
    @jit_buffer   = Fisk::Helpers.jitbuffer(4096 * 4)

    @top_exit     = @jit_buffer.memory

    __ = Fisk.new

    # Set up the top-level JIT return. This is for the JIT to return back to
    # the interpreter.  It assumes the return value has been placed in RAX
    # Pop the frame from the stack
    __.add(REG_CFP, __.imm32(RbControlFrameStruct.size))
    # Write the frame pointer back to the ec
    __.mov __.m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP
    __.ret
    __.write_to(@jit_buffer)

    @exits        = ExitCode.new @stats.to_i, @exit_stats.to_i
    @temp_stack   = TempStack.new
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
    rb_iseq = RubyVM::InstructionSequence.of(method)
    addr = method_to_iseq_t(rb_iseq)
    rb_iseq = RbISeqT.new(addr)
    rb_iseq.body.jit_func = 0
    cov_ptr = Fiddle.dlunwrap(rb_iseq.body.variable.coverage)
    cov_ptr[2] = nil if cov_ptr
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
    body  = RbISeqT.new(addr).body
    insns = Fiddle::CArray.unpack(body.iseq_encoded, body.iseq_size, Fiddle::TYPE_VOIDP)

    if body.jit_func.to_i != 0
      puts "already compiled!"
      return
    end

    @stats.compiled_methods += 1

    jit_head = @jit_buffer.memory + @jit_buffer.pos
    cb = CodeBlock.new jit_head

    # ec is in rdi
    # cfp is in rsi

    # Write the prologue for book keeping
    Fisk.new { |_|
      # Write the top exit to the PC.  JIT to JIT calls need to skip
      # this instruction
      _.mov(_.r10, _.imm64(@top_exit))
      _.mov(_.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), _.r10)

      _.mov(_.r10, _.imm64(@stats.to_i))
       .inc(_.m64(_.r10, Stats.offsetof("executed_methods")))
       .mov(REG_SP, _.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")))
    }.write_to(@jit_buffer)

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
        fisk.write_to(@jit_buffer)
      else
        make_exit(name, current_pc, @temp_stack.size).write_to @jit_buffer
        break
      end

      current_pc += rb.insn_len(insn) * Fiddle::SIZEOF_VOIDP
    end

    cb.finish = @jit_buffer.memory + @jit_buffer.pos
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

  def make_exit exit_insn_name, exit_pc, exit_sp
    jump_addr = @exits.make_exit(exit_insn_name, exit_pc, exit_sp)
    Fisk.new { |_|
      _.mov(_.r10, _.imm64(jump_addr))
       .jmp(_.r10)
    }
  end

  def handle_opt_lt current_pc, call_data

  def handle_opt_lt iseq_addr, current_pc, call_data
    sizeof_sp = member_size(RbControlFrameStruct, "sp")

    ts = @temp_stack

    __ = Fisk.new

    exit_addr = nil

    # Generate runtime checks if we need them
    2.times do |i|
      if ts.peek(i).type != T_FIXNUM
        exit_addr ||= @exits.make_exit("opt_lt", current_pc, @temp_stack.size)

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

  # Convert a method to an rb_iseq_t *address* (so, just the memory location
  # where the iseq exists)
  def method_to_iseq_t method
    RTypedData.new(Fiddle.dlwrap(method)).data.to_i
  end

  def rb; Internals; end

  def member_size struct, member
    self.class.member_size(struct, member)
  end

  def self.member_size struct, member
    fiddle_type = struct.types[struct.members.index(member)]
    Fiddle::PackInfo::SIZE_MAP[fiddle_type]
  end
end
