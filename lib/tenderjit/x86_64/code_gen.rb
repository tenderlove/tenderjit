require "fisk"

class TenderJIT
  module X86_64
    class CodeGen
      include Fisk::Registers

      attr_reader :asm

      def initialize
        @asm = Fisk.new
        @params = []
      end

      def write_to buffer
        @asm.write_to buffer
      end

      def handle insn, out, in1, in2
        insn.call self, out, in1, in2
      end

      def set_param _, arg1, _
        @params << arg1
      end

      def call _, location, params
        asm.mov RAX, location.pr
        params.each_with_index do |param, i|
          pr = param.pr
          next if pr == PARAM_REGS[i]
          asm.mov PARAM_REGS[i], pr
        end
        asm.call RAX
      end

      def neg out, arg1, _
        raise ArgumentError unless out.register?
        raise ArgumentError unless arg1.register?

        if out.pr != arg1.pr
          @asm.mov out.pr, arg1.pr
        end

        @asm.neg out.pr
      end

      def and out, arg1, arg2
        arg1 = _unwrap(arg1)
        arg2 = _unwrap(arg2)
        out  = _unwrap(out)

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
        if arg2.immediate?
          arg2 = @asm.uimm(arg2.pr)
        else
          arg2 = arg2.pr
        end

        if out.pr != arg1.pr
          @asm.mov out.pr, arg1.pr
        end

        @asm.sub out.pr, arg2
      end

      def add out, arg1, arg2
        arg1 = if arg1.immediate?
                 asm.uimm(arg1.pr)
               else
                 arg1.pr
               end

        arg2 = if arg2.immediate?
                 asm.uimm(arg2.pr)
               else
                 arg2.pr
               end

        case out.pr
        when arg1
          @asm.add out.pr, arg2
        when arg2
          @asm.add out.pr, arg1
        else
          @asm.mov out.pr, arg1
          @asm.add out.pr, arg2
        end
      end

      def load out, src, offset
        raise ArgumentError unless offset.immediate?
        raise ArgumentError unless src.register?
        raise ArgumentError unless out.register?

        @asm.mov out.pr, @asm.m64(src.pr, offset.pr)
      end

      def patch_location block, _, _
        asm.lazy(&block)
      end

      PARAM_REGS = [
        Fisk::Registers::RDI,
        Fisk::Registers::RSI,
        Fisk::Registers::RDX,
        Fisk::Registers::RCX,
        Fisk::Registers::R8,
        Fisk::Registers::R9,
      ]

      def save_params _, arg1, _
        arg1.pr.times.map.each_slice(2) { |x, y|
          x = PARAM_REGS[x]
          y = y ? PARAM_REGS[y] : x
          asm.push x
          asm.push y
        }
      end

      def restore_params _, arg1, _
        arg1.pr.times.map.each_slice(2).to_a.reverse_each { |x, y|
          x = PARAM_REGS[x]
          y = y ? PARAM_REGS[y] : x
          asm.pop y
          asm.pop x
        }
      end

      def push out, in1, in2
        raise ArgumentError unless in1.register?

        in2 = in2.register? ? in2.pr : in1.pr
        asm.push in2
        asm.push in1.pr
      end

      def pop out, in1, in2
        if in1.register?
          in2 = in2.register? ? in2.pr : in1.pr
          asm.pop in1.pr
          asm.pop in2
        else
          asm.add RSP, asm.uimm(16)
        end
      end

      def loadp out, offset, _
      end

      def loadsp _, _, _
      end

      def copy out, val, _
        asm.mov out.pr, val.pr
      end

      def loadi out, val, _
        raise ArgumentError unless val.immediate?

        val = if val.bits == 64
                asm.imm64 val.pr
              else
                asm.uimm val.pr
              end

        @asm.mov out.pr, val
      end

      def int2num dest, in1, _
        if dest.pr != in1.pr
          asm.mov dest.pr, in1.pr
        end

        asm.shl dest.pr, asm.uimm(1)
        asm.or dest.pr, asm.uimm(1)
      end

      def storei out, val, _
        loadi out, val, _
      end

      def store offset, val, dst
        raise ArgumentError unless offset.immediate?
        raise ArgumentError unless dst.register?

        @asm.mov @asm.m64(dst.pr, offset.pr), val.pr
      end

      def shr dest, reg, amount
        dest = _unwrap(dest)
        reg = _unwrap(reg)
        amount = _unwrap(amount)

        if dest != reg
          asm.mov dest, reg
        end

        asm.shr dest, amount
      end

      def jle dest, arg1, arg2
        arg2 = _unwrap(arg2)
        arg1 = _unwrap(arg1)

        @asm.cmp arg1, arg2
        @asm.jle asm.label(dest.pr)
      end

      def jmp dest, _, _
        if dest.integer?
          @asm.jmp @asm.uimm(dest)
        else
          @asm.jmp @asm.label(dest)
        end
      end

      def je dest, arg1, arg2
        if arg2.immediate?
          arg2 = @asm.uimm(arg2.pr)
        else
          arg2 = arg2.pr
        end

        if arg1.immediate?
          arg1 = @asm.uimm(arg1.pr)
        else
          arg1 = arg1.pr
        end

        asm.cmp arg1, arg2
        asm.je asm.label(dest.pr)
      end

      def put_label label, _, _
        @asm.put_label label
      end

      def jo dest, _, _
        @asm.jo asm.label(dest)
      end

      def cmp _, in1, in2
        asm.cmp in1.pr, in2.pr
      end

      def tbnz dest, arg1, arg2
        raise ArgumentError unless arg2.immediate?
        raise ArgumentError unless arg1.register?

        mask = (1 << arg2.pr)

        arg2 = @asm.uimm(mask)

        asm.test arg1.pr, arg2
        asm.jnz @asm.label(dest.pr)
      end

      def tbz dest, arg1, arg2
        raise ArgumentError unless arg2.immediate?
        raise ArgumentError unless arg1.register?

        mask = (1 << arg2.pr)

        arg2 = @asm.uimm(mask)

        asm.test arg1.pr, arg2
        asm.jz @asm.label(dest.pr)
      end

      ##
      # If the condition holds, then out == in1.
      # Otherwise in2
      def csel_lt out, in1, in2
        raise ArgumentError unless in1.register?
        raise ArgumentError unless in2.register?

        out = _unwrap(out)
        in1 = _unwrap(in1)
        in2 = _unwrap(in2)

        # Make sure false case (in2) is in out
        if out == in1
          # puts the false case in out.  True case should be in in2
          asm.xchg in1, in2
          asm.cmovl out, in2
        else
          if out != in2
            asm.mov out, in2
          end

          asm.cmovl out, in1
        end
      end

      def csel_gt out, in1, in2
        raise ArgumentError unless in1.register?
        raise ArgumentError unless in2.register?

        out = _unwrap(out)
        in1 = _unwrap(in1)
        in2 = _unwrap(in2)

        # Make sure false case (in2) is in out
        if out == in1
          # puts the false case in out.  True case should be in in2
          asm.xchg in1, in2
          asm.cmovg out, in2
        else
          if out != in2
            asm.mov out, in2
          end

          asm.cmovg out, in1
        end
      end

      def jnfalse dest, reg, _
        asm.test reg.pr, asm.imm(~Fiddle::Qnil)
        asm.jne asm.label(dest.pr)
      end

      def jfalse dest, reg, _
        asm.test reg.pr, asm.imm(~Fiddle::Qnil)
        asm.je asm.label(dest.pr)
      end

      def stack_alloc _, amount, _
        asm.sub Fisk::Registers::RSP, asm.uimm(amount)
      end

      def stack_free _, amount, _
        asm.add Fisk::Registers::RSP, asm.uimm(amount)
      end

      def write out, val, _
        if val.integer?
          @asm.mov out, @asm.uimm(val)
        else
          @asm.mov out, val
        end
      end

      def ret _, arg1, _
        if arg1.immediate?
          asm.mov RAX, asm.uimm(arg1.pr)
        elsif arg1.pr != RAX
          asm.mov RAX, arg1.pr
        end

        asm.ret
      end

      def brk _, _, _
        asm.int asm.lit(3)
      end

      private

      def _unwrap vr
        if vr.immediate?
          asm.uimm(vr.pr)
        else
          vr.pr
        end
      end
    end
  end
end
