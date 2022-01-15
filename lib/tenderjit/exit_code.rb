require "fisk"

class TenderJIT
  class ExitCode
    attr_reader :stats_addr, :exit_stats_addr, :jit_buffer

    def initialize jit_buffer, stats_addr, exit_stats_addr
      @jit_buffer      = jit_buffer
      @stats_addr      = stats_addr
      @exit_stats_addr = exit_stats_addr
    end

    def make_exit exit_insn_name, exit_pc, stack_depth
      fisk = Fisk.new

      stats_addr = fisk.imm64(self.stats_addr)
      exit_stats_addr = fisk.imm64(self.exit_stats_addr)

      __ = fisk
      __.with_register do |tmp|
        # increment the exits counter
        __.mov(tmp, stats_addr)
          .inc(__.m64(tmp, Stats.offsetof("exits")))

        offset = ExitStats.offsetof(exit_insn_name)
        raise "Unknown exit name #{exit_insn_name}" unless offset

        # increment the instruction specific counter
        __.mov(tmp, exit_stats_addr)
          .inc(__.m64(tmp, ExitStats.offsetof(exit_insn_name)))

        # Flush the SP
        __.lea(tmp, __.m(REG_BP, stack_depth * Fiddle::SIZEOF_VOIDP))
          .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("sp")), tmp)

        # Set the PC on the CFP
        __.mov(tmp, __.uimm(exit_pc))
          .mov(__.m64(REG_CFP, RbControlFrameStruct.offsetof("pc")), tmp)

        if $DEBUG
          print_str __, "EXITING! #{exit_insn_name}\n"
        end

        __.mov(__.rsp, REG_TOP)
        __.mov(__.rax, __.uimm(Qundef))
          .ret
      end
      __.assign_registers(ISEQCompiler::SCRATCH_REGISTERS, local: true)

      jump_location = @jit_buffer.memory.to_i + @jit_buffer.pos
      fisk.write_to(@jit_buffer)
      jump_location
    end

    def print_str fisk, string
      fisk.jmp(fisk.label(:after_bytes))
      pos = nil
      fisk.lazy { |x| pos = x; string.bytes.each { |b| jit_buffer.putc b } }
      fisk.put_label(:after_bytes)
      fisk.mov fisk.rdi, fisk.uimm(2)
      fisk.lazy { |x|
        fisk.mov fisk.rsi, fisk.uimm(jit_buffer.memory + pos)
      }
      fisk.mov fisk.rdx, fisk.uimm(string.bytesize)
      fisk.mov fisk.rax, fisk.uimm(0x02000004)
      fisk.syscall
    end
  end
end
