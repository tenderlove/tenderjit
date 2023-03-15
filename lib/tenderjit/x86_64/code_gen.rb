require "fisk"

class TenderJIT
  module X86_64
    class CodeGen
      attr_reader :asm

      def initialize
        @asm = Fisk.new
        @params = []
      end

      def write_to buffer
        @asm.write_to buffer
      end

      def handle insn, out, in1, in2
        send insn.op, out, in1, in2
      end

      private

      def set_param _, arg1, _
        @params << arg1
      end

      def call _, location, arity
        @params.pop(arity).each_with_index do |param, i|
          param_reg = PARAM_REGS[i]
          if param != param_reg
            param = @asm.uimm(param) if param.integer?
            asm.mov param_reg, param
          end
        end
        asm.call location
      end

      def neg out, arg1, _
        if out != arg1
          @asm.mov out, arg1
        end

        @asm.neg out
      end

      def and out, arg1, arg2
        arg1 = @asm.uimm(arg1) if arg1.integer?
        arg2 = @asm.uimm(arg2) if arg2.integer?

        case out
        when arg1
          @asm.and out, arg2
        when arg2
          @asm.and out, arg1
        else
          @asm.mov out, arg1
          @asm.and out, arg2
        end
      end

      def sub out, arg1, arg2
        arg2 = @asm.uimm(arg2) if arg2.integer?

        if out != arg1
          @asm.mov out, arg1
        end

        @asm.sub out, arg2
      end

      def add out, arg1, arg2
        arg1 = @asm.uimm(arg1) if arg1.integer?
        arg2 = @asm.uimm(arg2) if arg2.integer?

        case out
        when arg1
          @asm.add out, arg2
        when arg2
          @asm.add out, arg1
        else
          @asm.mov out, arg1
          @asm.add out, arg2
        end
      end

      def load out, src, offset
        @asm.mov out, @asm.m64(src, offset)
      end

      def loadi out, val, _
        @asm.mov out, @asm.uimm(val)
      end

      def store offset, val, dst
        @asm.mov @asm.m64(dst, offset), val
      end

      def jle dest, arg1, arg2
        arg2 = @asm.uimm(arg2) if arg2.integer?
        arg1 = @asm.uimm(arg1) if arg1.integer?

        @asm.cmp arg1, arg2
        @asm.jle asm.label(dest)
      end

      def jmp dest, _, _
        if dest.integer?
          @asm.jmp @asm.uimm(dest)
        else
          @asm.jmp @asm.label(dest)
        end
      end

      def je dest, arg1, arg2
        arg2 = @asm.uimm(arg2) if arg2.integer?
        arg1 = @asm.uimm(arg1) if arg1.integer?

        asm.cmp arg1, arg2
        asm.je asm.label(dest)
      end

      def put_label label, _, _
        @asm.put_label label
      end

      def jo dest, _, _
        @asm.jo asm.label(dest)
      end

      def cmp _, in1, in2
        asm.cmp in1, in2
      end

      def tbnz dest, arg1, arg2
        raise ArgumentError unless arg2.integer?
        raise ArgumentError unless arg1.register?

        mask = (1 << arg2)

        arg2 = @asm.uimm(mask)

        asm.test arg1, arg2
        asm.jnz @asm.label(dest)
      end

      def tbz dest, arg1, arg2
        raise ArgumentError unless arg2.integer?
        raise ArgumentError unless arg1.register?

        mask = (1 << arg2)

        arg2 = @asm.uimm(mask)

        asm.test arg1, arg2
        asm.jz @asm.label(dest)
      end

      def csel_lt out, in1, in2
        raise ArgumentError unless in1.register?
        raise ArgumentError unless in2.register?

        if out != in1
          asm.mov out, in2
        end

        asm.cmovl out, in1
      end

      def csel_gt out, in1, in2
        raise ArgumentError unless in1.register?
        raise ArgumentError unless in2.register?

        if out != in1
          asm.mov out, in2
        end

        asm.cmovg out, in1
      end

      def jnfalse dest, reg, _
        asm.test reg, asm.imm(~Fiddle::Qnil)
        asm.jne asm.label(dest)
      end

      def jfalse dest, reg, _
        asm.test reg, asm.imm(~Fiddle::Qnil)
        asm.je asm.label(dest)
      end

      def write out, val, _
        if val.integer?
          @asm.mov out, @asm.uimm(val)
        else
          @asm.mov out, val
        end
      end

      def return _, arg1, _
        if arg1 != Fisk::Registers::RAX || arg1.integer?
          arg1 = @asm.uimm(arg1) if arg1.integer?
          asm.mov Fisk::Registers::RAX, arg1
        end

        asm.ret
      end

      def brk _, _, _
        asm.int asm.lit(3)
      end
    end
  end
end
