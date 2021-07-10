require "tenderjit/ruby_internals"
require "tenderjit/fiddle_hacks"
require "fiddle/import"
require "fisk"

class TenderJIT
  Internals = RubyInternals.get_internals

  # Struct layouts

  RTypedData            = Internals.struct("RTypedData")
  Rb_ISeq_T             = Internals.struct("rb_iseq_t")
  Rb_ISeq_Constant_Body = Internals.struct("rb_iseq_constant_body")
  RbControlFrameStruct  = Internals.struct("rb_control_frame_struct")
  RbExecutionContextT   = Internals.struct("rb_execution_context_t")

  # Global Variables

  MJIT_CALL_P = Fiddle::Pointer.new(Internals.symbol_address("mjit_call_p"))
  MJIT_OPTIONS = Internals.struct("mjit_options").new(Internals.symbol_address("mjit_opts"))

  MJIT_OPTIONS.min_calls = 5
  MJIT_OPTIONS.wait = 0

  # Important Addresses

  VM_EXEC_CORE = Internals.symbol_address("vm_exec_core")

  extend Fiddle::Importer

  Stats = struct [
    "uint64_t compiled_methods",
    "uint64_t executed_methods",
    "uint64_t exits",
  ]

  ExitStats = struct RubyVM::INSTRUCTION_NAMES.map { |n|
    "uint64_t #{n}"
  }

  def initialize
    @stats = Stats.malloc(Fiddle::RUBY_FREE)
    @stats.compiled_methods = 0
    @stats.executed_methods = 0

    @exit_stats = ExitStats.malloc(Fiddle::RUBY_FREE)
    @jit_buffer = Fisk::Helpers.jitbuffer(4096 * 4)
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

  def enable!
    MJIT_OPTIONS.on = 1
    MJIT_CALL_P[0] = 1
  end

  def disable!
    MJIT_OPTIONS.on = 0
    MJIT_CALL_P[0] = 0
  end

  private

  REG_EC  = Fisk::Registers::RDI
  REG_CFP = Fisk::Registers::RSI

  def compile_iseq_t addr
    @stats.compiled_methods += 1

    body  = Rb_ISeq_Constant_Body.new Rb_ISeq_T.new(addr).body
    insns = Fiddle::CArray.unpack(body.iseq_encoded, body.iseq_size, Fiddle::TYPE_VOIDP)

    jit_head = @jit_buffer.memory + @jit_buffer.pos

    # ec is in rdi
    # cfp is in rsi

    # Write the prologue for book keeping
    Fisk.new { |_|
      _.mov(_.r10, _.imm64(@stats.to_i))
       .inc(_.m64(_.r10, Stats.offsetof("executed_methods")))
    }.write_to(@jit_buffer)

    offset = 0

    while insn = insns.shift
      name   = rb.insn_name(insn)
      params = insns.shift(rb.insn_len(insn) - 1)

      if respond_to?("handle_#{name}", true)
        fisk = send("handle_#{name}", *params)
        fisk.write_to(@jit_buffer)
      else
        exit_pc = body.iseq_encoded.to_i + (offset * Fiddle::SIZEOF_VOIDP)
        make_exit(name, exit_pc).write_to @jit_buffer
        break
      end

      offset += rb.insn_len(insn)
    end

    body.jit_func = jit_head
  end

  def make_exit exit_insn_name, exit_pc
    fisk = Fisk.new

    stats_addr = @stats.to_i
    exit_stats_addr = @exit_stats.to_i

    fisk.instance_eval do
      # increment the exits counter
      mov r10, imm64(stats_addr)
      inc m64(r10, Stats.offsetof("exits"))

      # increment the instruction specific counter
      mov r10, imm64(exit_stats_addr)
      inc m64(r10, ExitStats.offsetof(exit_insn_name))

      # Set the PC on the CFP
      mov r10, imm64(exit_pc)
      mov m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), r10

      reg_ep = r11

      # Set VM_FRAME_FLAG_FINISH so that vm_exec_core will return
      mov reg_ep, m64(REG_CFP, RbControlFrameStruct.offsetof("ep"))
      mov rax, m64(reg_ep)
      self.or rax, imm32(Internals.c("VM_FRAME_FLAG_FINISH"))
      mov m64(reg_ep), rax

      # EC is already in RDI, so we don't need to put it there
      # mov rdi, REG_EC
      mov rsi, imm32(0) # "initial"
      mov r10, imm64(VM_EXEC_CORE)

      push rsp
      call r10
      pop rsp
      ret
    end

    fisk
  end

  def handle_putself
    sizeof_sp = member_size(RbControlFrameStruct, "sp")

    fisk = Fisk.new

    fisk.instance_eval do
      reg_sp   = r10
      reg_self = r11

      # Increment the SP
      mov reg_sp, m64(REG_CFP, RbControlFrameStruct.offsetof("sp"))
      add reg_sp, imm32(sizeof_sp)

      # Write the SP back to the CFP
      mov m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), reg_sp

      # Get self from the CFP
      mov reg_self, m64(REG_CFP, RbControlFrameStruct.offsetof("self"))

      # Write self to the top of the stack
      mov m64(reg_sp, -sizeof_sp), reg_self
    end

    fisk
  end

  def handle_putobject literal
    sizeof_sp = member_size(RbControlFrameStruct, "sp")

    fisk = Fisk.new

    fisk.instance_eval do
      reg_sp = r10

      # Increment the SP
      mov reg_sp, m64(REG_CFP, RbControlFrameStruct.offsetof("sp"))
      add reg_sp, imm32(sizeof_sp)

      # Write the SP back to the CFP
      mov m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), reg_sp

      # Write the literal to the top of the stack
      mov r11, imm64(literal)
      mov m64(reg_sp, -sizeof_sp), r11
    end

    fisk
  end

  # `leave` instruction
  def handle_leave
    sizeof_sp = member_size(RbControlFrameStruct, "sp")

    # FIXME: We need to check interrupts and exit
    fisk = Fisk.new
    fisk.instance_eval do
      reg_sp = r10

      # Copy top value from the stack in to rax
      #   `VALUE val = TOP(0);`
      mov reg_sp, m64(REG_CFP, RbControlFrameStruct.offsetof("sp"))
      mov rax, m64(reg_sp, -sizeof_sp)

      # Decrement SP and write it back to the CFP
      #   `POPN(1)`
      sub reg_sp, imm32(sizeof_sp)
      mov m64(REG_CFP, sizeof_sp), reg_sp

      # Pop the frame from the stack
      add REG_CFP, imm32(RbControlFrameStruct.size)

      # Write the frame pointer back to the ec
      mov m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP

      ret
    end

    fisk
  end

  # Convert a method to an rb_iseq_t *address* (so, just the memory location
  # where the iseq exists)
  def method_to_iseq_t method
    RTypedData.new(Fiddle.dlwrap(method)).data.to_i
  end

  def rb; Internals; end

  def member_size struct, member
    fiddle_type = struct.types[struct.members.index(member)]
    Fiddle::PackInfo::SIZE_MAP[fiddle_type]
  end
end
