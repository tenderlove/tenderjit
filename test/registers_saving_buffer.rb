#!/usr/bin/env ruby

require "fisk"
require "fisk/helpers"

include Fisk::Registers

# A JIT buffer that, after execution, saves the registers content to a separate
# location, so that they can be tested.
#
# In order to use:
#
#     jit_buffer_memory = Fisk::Helpers.mmap_jit(4096)
#     saving_buffer = RegistersSavingBuffer.new jit_buffer_memory, 4096
#     # ... write to the buffer as it was a normal JIT buffer ...
#     saving_buffer.to_function([], Fiddle::TYPE_VOID).call
#     assert_equal 1, saving_buffer.register_value(RAX)
#
# The design can easily be turned into a proxy around a JIT Buffer, if needed.
#
class RegistersSavingBuffer < Fisk::Helpers::JITBuffer
  # In push order, which is the reverse order of storage/read. RSP +must+ be the
  # first, in order to store the original value.
  #
  SAVED_REGISTERS = [RSP, R15, R14, R13, R12, R11, R10, R9, R8, RBP, RSI, RDI, RDX, RCX, RBX, RAX]

  def initialize memory, size
    super

    # The +8 bytes are used to store the caller return address.
    #
    @data_buffer = Fisk::Helpers.jitbuffer(SAVED_REGISTERS.size * 8 + 8).memory
  end

  # Run the wrapper buffer, which in turn, runs the JIT buffer.
  # After invoking this method, the saved registers are available through the dedicated
  # APIs.
  #
  def to_function params, ret
    # Since the wrapper buffer calls the JIT buffer without any change, we don't
    # need to care about parameters/stack, because in the current functionality
    # scope, parameters are passed only via registers.
    #
    wrapper_buffer = prepare_wrapper_buffer
    Fiddle::Function.new wrapper_buffer.memory.to_i, params, ret
  end

  # Returns { "register.name" => uint_value }.
  #
  def register_values
    SAVED_REGISTERS.reverse.each_with_object({}).with_index do |(reg, result), i|
      decoded_value = @data_buffer[8 * i, 8].unpack1("Q")
      result[reg.name] = decoded_value
    end
  end

  def register_value reg
    register_values.fetch reg.name
  end

  # List of "register_name: hex_value"
  #
  # arguments:
  # :regs: if set, only those regs are printed
  #
  def print_register_values(*regs)
    print_regs = regs.map &:name

    register_values.each do |reg_name, value|
      puts "%3s: 0x%016x" % [reg_name, value] if regs.empty? || print_regs.include?(reg_name)
    end
  end

  private

  def prepare_wrapper_buffer
    fisk = Fisk.new

    wrapper_buffer = Fisk::Helpers.jitbuffer 4096

    # Must include the jmp length (5).
    #
    rel_return_in_wrapper_buffer = 0x2a

    jit_buffer_rel_addr = memory.to_i - wrapper_buffer.memory.to_i - rel_return_in_wrapper_buffer

    data_buffer = @data_buffer

    fisk.asm(wrapper_buffer) do
      ##########################################################################
      # Save and patch the return address
      ##########################################################################

      # We do this so that the jmp acts as a call; we can't use a call becuase it
      # would modify the stack.
      # Since we push two registers, we need to take them into account when finding
      # the return address in the stack.
      # When modifying this, update `rel_return_in_wrapper_buffer``.

      push RAX
      push RBX

      mov RAX, m64(RSP, 2 * 8)
      mov RBX, imm64(data_buffer.to_i + SAVED_REGISTERS.size * 8)
      mov m64(RBX), RAX

      mov RAX, imm64(wrapper_buffer.memory.to_i + rel_return_in_wrapper_buffer)
      mov m64(RSP, 2 * 8), RAX

      pop RBX
      pop RAX

      ##########################################################################
      # Invoke the original function
      ##########################################################################

      jmp Fisk::Rel32.new(jit_buffer_rel_addr)

      ##########################################################################
      # Store register values
      ##########################################################################

      # Technically, pushes move the SP first then store the value, so intuitively,
      # we'd need to recompute the saved SP; this is not the case though - the pre-push
      # SP value is actually pushed to the stack.
      #
      SAVED_REGISTERS.each do |reg|
        push reg
      end

      mov RSI, RSP
      mov RDI, imm64(data_buffer.to_i)
      mov RCX, imm64(SAVED_REGISTERS.size)

      # Can't generate REP MOV* via Fisk!
      #
      # The below is a naive implementation; at a quick look, it seems that Fisk
      # doesn't support the form `mov [rax, rsi + 8 * rcx]`, which would simplify
      # the logic.
      #
      put_label :copy_stack
      mov RAX, m64(RSI)
      mov m64(RDI), RAX
      add RSI, imm8(8)
      add RDI, imm8(8)
      dec RCX
      jnz label(:copy_stack)

      SAVED_REGISTERS.reverse.each do |reg|
        pop reg
      end

      ##########################################################################
      # Return to the caller
      ##########################################################################

      # Put the callee return address in the stack, and return.

      push RAX # reserve space for the return address

      push RAX
      push RBX

      mov RBX, imm64(data_buffer.to_i + SAVED_REGISTERS.size * 8)
      mov RAX, m64(RBX)
      mov m64(RSP, 2 * 8), RAX

      pop RBX
      pop RAX

      ret
    end

    wrapper_buffer
  end
end
