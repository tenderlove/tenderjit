class TenderJIT
  class JITBufferProxy
    def initialize jb
      @jb = jb
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
  end
end
