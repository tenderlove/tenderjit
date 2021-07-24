class TenderJIT
  class JITBufferProxy
    def initialize jb
      @jb = jb
      write_return
    end

    def top_exit
      @jb.memory
    end

    def memory
      @jb.memory
    end

    def pos
      @jb.pos
    end

    def putc c
      @jb.putc c
    end

    def seek a, b
      @jb.seek a, b
    end

    private

    def write_return
      __ = Fisk.new

      # Set up the top-level JIT return. This is for the JIT to return back to
      # the interpreter.  It assumes the return value has been placed in RAX
      # Pop the frame from the stack
      __.add(REG_CFP, __.imm32(RbControlFrameStruct.size))
      # Write the frame pointer back to the ec
      __.mov __.m64(REG_EC, RbExecutionContextT.offsetof("cfp")), REG_CFP
      __.ret
      __.write_to(@jb)
    end
  end
end
