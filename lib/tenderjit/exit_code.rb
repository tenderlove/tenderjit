require "fisk"

class TenderJIT
  class ExitCode
    attr_reader :stats_addr, :exit_stats_addr

    def initialize stats_addr, exit_stats_addr
      @jit_buffer      = Fisk::Helpers.jitbuffer(4096 * 4)
      @stats_addr      = stats_addr
      @exit_stats_addr = exit_stats_addr
    end

    def make_exit exit_insn_name, exit_pc, exit_sp
      fisk = Fisk.new

      sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")

      stats_addr = fisk.imm64(self.stats_addr)
      exit_stats_addr = fisk.imm64(self.exit_stats_addr)

      fisk.instance_eval do
        # increment the exits counter
        mov r10, stats_addr
        inc m64(r10, Stats.offsetof("exits"))

        # increment the instruction specific counter
        mov r10, exit_stats_addr
        inc m64(r10, ExitStats.offsetof(exit_insn_name))

        # increment the SP
        add REG_SP, imm32(sizeof_sp * exit_sp)
        mov m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), REG_SP

        # Set the PC on the CFP
        mov r10, imm64(exit_pc)
        mov m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), r10

        mov m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP

        mov rax, imm64(Qundef)
        ret
      end

      jump_location = @jit_buffer.memory.to_i + @jit_buffer.pos
      fisk.write_to(@jit_buffer)
      jump_location
    end
  end
end
