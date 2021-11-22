require "helper"

class TenderJIT
  class RegistersSavingBufferTest < Test
    def prepare_buffer
      fisk = Fisk.new

      buffer = RegistersSavingBuffer.new Fisk::Helpers.mmap_jit(4096), 4096

      fisk.asm(buffer) do
        # Avoid messing with RSP/RBP
        mov RAX, fisk.imm64(0x02_03_04_05)
        mov RBX, fisk.imm64(0x03_04_05_06)
        mov RCX, fisk.imm64(0x04_05_06_07)
        mov RDX, fisk.imm64(0x05_06_07_08)
        mov RSI, fisk.imm64(0x06_07_08_09)
        mov RDI, fisk.imm64(0x07_08_09_10)
        mov R8,  fisk.imm64(0x09_10_11_12)
        mov R9,  fisk.imm64(0x10_11_12_13)
        mov R10, fisk.imm64(0x11_12_13_14)
        mov R11, fisk.imm64(0x12_13_14_15)
        mov R12, fisk.imm64(0x13_14_15_16)
        mov R13, fisk.imm64(0x14_12_10_08)
        mov R14, fisk.imm64(0x15_13_11_09)
        mov R15, fisk.imm64(0xde_ad_ca_fe)

        ret
      end

      buffer
    end

    def test_saving
      buffer = prepare_buffer

      buffer.to_function([], Fiddle::TYPE_VOID).call

      assert_equal buffer.saved_rax, 0x02_03_04_05
      assert_equal buffer.saved_rbx, 0x03_04_05_06
      assert_equal buffer.saved_rcx, 0x04_05_06_07
      assert_equal buffer.saved_rdx, 0x05_06_07_08
      assert_equal buffer.saved_rsi, 0x06_07_08_09
      assert_equal buffer.saved_rdi, 0x07_08_09_10
      assert_equal buffer.saved_r8,  0x09_10_11_12
      assert_equal buffer.saved_r9,  0x10_11_12_13
      assert_equal buffer.saved_r10, 0x11_12_13_14
      assert_equal buffer.saved_r11, 0x12_13_14_15
      assert_equal buffer.saved_r12, 0x13_14_15_16
      assert_equal buffer.saved_r13, 0x14_12_10_08
      assert_equal buffer.saved_r14, 0x15_13_11_09
      assert_equal buffer.saved_r15, 0xde_ad_ca_fe
    end
  end # RegistersSavingBufferTest
end # TenderJIT
