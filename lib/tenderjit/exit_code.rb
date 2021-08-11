require "fisk"

class TenderJIT
  class ExitCode
    attr_reader :stats_addr, :exit_stats_addr

    def initialize jit_buffer, stats_addr, exit_stats_addr
      @jit_buffer      = jit_buffer
      @stats_addr      = stats_addr
      @exit_stats_addr = exit_stats_addr
    end

    def make_exit exit_insn_name, exit_pc, temp_stack
      fisk = Fisk.new

      sizeof_sp = TenderJIT.member_size(RbControlFrameStruct, "sp")

      stats_addr = fisk.imm64(self.stats_addr)
      exit_stats_addr = fisk.imm64(self.exit_stats_addr)

      __ = fisk
      __.with_register do |tmp|
        # increment the exits counter
        __.mov(tmp, stats_addr)
          .inc(__.m64(tmp, Stats.offsetof("exits")))

        # increment the instruction specific counter
        __.mov(tmp, exit_stats_addr)
          .inc(__.m64(tmp, ExitStats.offsetof(exit_insn_name)))

        # increment the SP
        temp_stack.flush(__)

        # Set the PC on the CFP
        __.mov(tmp, __.uimm(exit_pc))
          .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), tmp)

        __.mov(__.rax, __.uimm(Qundef))
          .ret
      end
      __.assign_registers(ISEQCompiler::SCRATCH_REGISTERS, local: true)

      jump_location = @jit_buffer.memory.to_i + @jit_buffer.pos
      fisk.write_to(@jit_buffer)
      jump_location
    end
  end
end
