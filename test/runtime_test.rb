# frozen_string_literal: true

require "helper"

class TenderJIT
  class RuntimeTest < Test
    include Fisk::Registers
    SCRATCH_REGISTERS = ISEQCompiler::SCRATCH_REGISTERS

    attr_reader :rt, :saving_buffer

    def setup
      super

      fisk = Fisk.new
      @saving_buffer = RegistersSavingBuffer.new Fisk::Helpers.mmap_jit(4096), 4096
      temp_stack = TempStack.new

      @rt = Runtime::new(fisk, @saving_buffer, temp_stack)
    end

    # Allocate and set the data required to print a DP-float.
    #
    # Returns the addresses of the template and the float.
    #
    def prepare_printf_data
      template = "%f\x00".bytes
      fp_value = [0, 0, 0, 0, 0, 0, 0xF0, 0x3F] # Any valid double will do; this is 1.0

      data_buffer = Fisk::Helpers.jitbuffer template.size + fp_value.size

      template.each { |byte| data_buffer.putc byte }
      fp_value.each { |byte| data_buffer.putc byte }

      data_buffer.seek 0

      [data_buffer.memory.to_i, data_buffer.memory.to_i + template.size]
    end

    # Prepare a function that overwrites the scratch (as defined in the ISEQCompiler
    # class) registers.
    #
    # Returns the location of the buffer/function.
    #
    def prepare_temp_var_regs_overwriting_func
      buffer = Fisk::Helpers::JITBuffer.new(Fisk::Helpers.mmap_jit(4096), 4096)
      fisk = Fisk.new

      fisk.asm(buffer) do
        xor SCRATCH_REGISTERS[0], SCRATCH_REGISTERS[0]
        xor SCRATCH_REGISTERS[1], SCRATCH_REGISTERS[1]

        ret
      end

      buffer.memory.to_i
    end

    def test_if_eq_imm8_imm64_false_branch
      rt.if_eq(2 << 0, 2 << 32) {
        rt.write RAX, 1
      }.else {
        rt.write RAX, 2
      }

      rt.return
      rt.write!
      saving_buffer.to_function([], Fiddle::TYPE_VOID).call

      assert_equal 2, saving_buffer.register_value(RAX)
    end

    # Originally design to verify comparing an imm8 with an immediate less than
    # 64 bits wide (this UT therefore tests two things).
    #
    def test_if_eq_imm8_imm8_true_branch
      rt.if_eq(2 << 0, 2 << 0) {
        rt.write RAX, 1
      }.else {
        rt.write RAX, 2
      }

      rt.return
      rt.write!
      saving_buffer.to_function([], Fiddle::TYPE_VOID).call

      assert_equal 1, saving_buffer.register_value(RAX)
    end

    # See https://github.com/tenderlove/tenderjit/issues/35#issuecomment-934872857
    #
    # > The code in main is emitting an extra mov instruction because the lhs is
    # > an immediate when we could have put the lhs in the rhs and directly used
    # > the CMP instruction.
    #
    # When tackling, update all the invocations, then turn the swap into an
    # assertion.
    #
    def test_if_eq_imm_not_imm
      skip "Optimize the if_eq invocations"
    end

    def test_inc
      rt.xor RAX, RAX
      rt.inc RAX

      rt.return
      rt.write!
      saving_buffer.to_function([], Fiddle::TYPE_VOID).call

      assert_equal 1, saving_buffer.register_value(RAX)
    end

    # The call_cfunc are meant to raise a segment violation if the alignment is
    # not performed, and not raise anything otherwise.
    # The following UTs do +not+ cover all the cases.
    #
    # Prints `1.000000%` to the stdout; not sure if this can be avoided trivially.
    #
    def test_call_cfunc_auto_alignment
      printf = Fiddle::Handle::DEFAULT["printf"]

      template_loc, float_loc = prepare_printf_data

      rt.write R11, float_loc
      rt.movsd Register.new("xmm", "xmm0", 0), Fisk::M64.new(R11, 0)
      rt.write RAX, 1
      rt.call_cfunc printf, [template_loc], auto_align: true, call_reg: R10

      rt.return
      rt.write!
      saving_buffer.to_function([], Fiddle::TYPE_VOID).call

      # If we get here, all is well!
    end

    def test_call_cfunc_save_temp_var_regs
      temp_var_regs_overwriting_func = prepare_temp_var_regs_overwriting_func

      rt.temp_var do |tv1|
        rt.temp_var do |tv2|
          tv1.write 1
          tv2.write 2

          rt.call_cfunc temp_var_regs_overwriting_func, []

          # We do know which the scratch registers are, but it's better not to use
          # information that, from this level of abstraction, is better to keep hidden.
          #
          rt.write RAX, tv1
          rt.write RBX, tv2
        end
      end

      rt.return
      rt.write!

      saving_buffer.to_function([], Fiddle::TYPE_VOID).call

      assert_equal 1, saving_buffer.saved_rax
      assert_equal 2, saving_buffer.saved_rbx
    end
  end # class RuntimeTest
end
