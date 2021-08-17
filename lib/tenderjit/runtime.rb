class TenderJIT
  class Runtime
    def initialize fisk
      @fisk = fisk
      yield self
    end

    def pointer reg, type = Fiddle::TYPE_VOIDP
      Pointer.new reg, type, find_size(type), self
    end

    def sub reg, val
      @fisk.sub reg, @fisk.uimm(val)
    end

    def write_immediate reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.uimm(val))
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def with_ref reg, offset
      @fisk.with_register do |tmp|
        @fisk.lea(tmp, @fisk.m(reg, offset))
        yield tmp
      end
    end

    def write_register dst, offset, src
      @fisk.mov(@fisk.m64(dst, offset), src)
    end

    def break
      @fisk.int(@fisk.lit(3))
    end

    private

    def find_size type
      type == Fiddle::TYPE_VOIDP ? Fiddle::SIZEOF_VOIDP : type.size
    end

    class Pointer
      attr_reader :reg, :type, :size

      def initialize reg, type, size, event_coordinator
        @reg    = reg
        @type   = type
        @size   = size
        @ec     = event_coordinator
      end

      def []= idx, val
        @ec.write_immediate @reg, idx * size, val
      end

      # Mutates this pointer.  Subtracts the size from itself.  Similar to
      # C's `--` operator
      def sub
        @ec.sub reg, size
      end

      def with_ref offset
        @ec.with_ref(@reg, offset * size) do |reg|
          yield Pointer.new(reg, type, size, @ec)
        end
      end

      def method_missing m, *values
        return super if type == Fiddle::TYPE_VOIDP

        member = m.to_s
        v      = values.first

        if m =~ /^(.*)=/
          member = $1
        else
          raise NotImplementedError, "don't support reads yet"
        end

        return super unless type.members.include?(member)

        if v.is_a?(Pointer)
          @ec.write_register @reg, type.offsetof(member), v.reg
        else
          @ec.write_immediate @reg, type.offsetof(member), v.to_i
        end
      end
    end
  end
end
