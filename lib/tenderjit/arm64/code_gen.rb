require "aarch64"

class TenderJIT
  module ARM64
    class CodeGen
      include AArch64::Registers

      attr_reader :asm

      def initialize
        @asm = AArch64::Assembler.new
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

      def jnfalse dest, reg, _
        asm.tst reg.pr, ~Fiddle::Qnil
        asm.b dest.pr, cond: :ne
      end

      def jfalse dest, reg, _
        asm.tst reg.pr, ~Fiddle::Qnil
        asm.b dest.pr, cond: :eq
      end

      def tbz dest, reg, bit
        asm.tbz reg.pr, bit.pr, dest.pr
      end

      def shr dest, reg, amount
        asm.asr dest.pr, reg.pr, amount.pr
      end

      def jle dest, arg1, arg2
        asm.cmp arg1.pr, arg2.pr
        asm.b dest.pr, cond: :le
      end

      def jne dest, arg1, arg2
        asm.cmp arg1, arg2
        asm.b dest, cond: :ne
      end

      def tbnz dest, arg1, arg2
        asm.tbnz arg1.pr, arg2.pr, dest.pr
      end

      def je dest, arg1, arg2
        asm.cmp arg1.pr, arg2.pr
        asm.b dest.pr, cond: :eq
      end

      def neg out, arg1, _
        asm.neg out.pr, arg1.pr
      end

      PARAM_REGS = 8.times.map { AArch64::Registers.const_get(:"X#{_1}") }.freeze

      def save_params _, arg1, _
        arg1.pr.times.map.each_slice(2) { |x, y|
          x = PARAM_REGS[x]
          y = y ? PARAM_REGS[y] : XZR
          asm.stp x, y, [SP, -16], :!
        }
      end

      def restore_params _, arg1, _
        arg1.pr.times.map.each_slice(2).to_a.reverse_each { |x, y|
          x = PARAM_REGS[x]
          y = y ? PARAM_REGS[y] : XZR
          asm.ldp x, y, [SP], 16
        }
      end

      def call _, location, params
        params.each_with_index do |param, i|
          pr = param.pr
          next if pr == PARAM_REGS[i]
          asm.mov PARAM_REGS[i], pr
        end
        # Save these regs
        asm.stp X30, XZR, [SP, -16], :!
        asm.blr location.pr
        asm.ldp X30, XZR, [SP], 16
      end

      def patch_location block, _, _
        asm.patch_location(&block)
      end

      def and out, arg1, arg2
        if arg1.immediate? && arg2.immediate?
          asm.movk(out.pr, arg1.pr & arg2.pr)
        else
          if arg1.immediate?
            asm.movk(out.pr, arg1.pr)
            arg1 = out
          end

          if arg2.immediate?
            asm.movk(out.pr, arg2.pr)
            arg2 = out
          end

          asm.and out.pr, arg1.pr, arg2.pr
        end
      end

      def add out, arg1, arg2
        if arg1.immediate?
          arg1, arg2 = arg2, arg1
        end

        asm.adds out.pr, arg1.pr, arg2.pr
      end

      def mod out, arg1, arg2
        asm.str X24, [SP, -16], :!
        asm.udiv X24, arg1.pr, arg2.pr
        asm.msub out.pr, X24, arg2.pr, arg1.pr
        asm.ldr X24, [SP], 16
      end

      def sub out, arg1, arg2
        if arg1.immediate? && arg2.immediate?
          asm.movz out.pr, arg1.pr - arg2.pr
          return
        else
          if arg1.immediate?
            raise
          end
        end

        asm.sub out.pr, arg1.pr, arg2.pr
      end

      def ret _, arg1, _
        if arg1.immediate?
          asm.mov AArch64::Registers::X0, arg1.pr
        elsif arg1.pr != AArch64::Registers::X0
          asm.mov AArch64::Registers::X0, arg1.pr
        end

        asm.ret
      end

      def store offset, val, dst
        asm.stur val.pr, [dst.pr, offset.pr]
      end

      def load out, src, offset
        asm.ldur out.pr, [src.pr, offset.pr]
      end

      def loadp _, _, _
      end

      def storep out, reg, _
        write out, reg, _
      end

      def loadsp _, _, _
      end

      def dec _, reg, amount
        asm.sub reg, reg, amount
      end

      def loadi out, val, _
        raise ArgumentError unless val.immediate?

        shift = if val.bits
                  val.bits / 16
                else
                  if val.pr >> 48 > 0
                    4
                  else
                    if val.pr >> 32 > 0
                      3
                    else
                      if val.pr >> 16 > 0
                        2
                      else
                        1
                      end
                    end
                  end
                end

        val = val.pr

        shift.times do |i|
          if i == 0
            asm.movz out.pr, val & 0xFFFF, lsl: 0
          else
            asm.movk out.pr, val & 0xFFFF, lsl: (i * 16)
          end
          val >>= 16
        end
      end

      def storei out, val, _
        loadi out, val, _
      end

      def copy out, val, _
        asm.mov out.pr, val.pr
      end

      def write out, val, _
        if val.integer?
          loadi out, val, _
        else
          asm.mov out, val
        end
      end

      def brk _, _, _
        asm.brk 1
      end

      def nop _, _, _
        asm.nop
      end

      def jmp out, _, _
        asm.b out
      end

      def jo dest, _, _
        asm.b dest, cond: :vs
      end

      def cmp _, in1, in2
        asm.cmp in1.pr, in2.pr
      end

      def csel_lt out, in1, in2
        in2 = in2.pr == 0 ? XZR : in2.pr
        asm.csel out.pr, in1.pr, in2, :lt
      end

      def csel_gt out, in1, in2
        in2 = in2.pr == 0 ? XZR : in2.pr
        asm.csel out.pr, in1.pr, in2, :gt
      end

      def push out, in1, in2
        in2 = in2.register? ? in2.pr : XZR
        asm.stp in1.pr, in2, [SP, -16], :!
      end

      def pop out, in1, in2
        if in1.register?
          in2 = in2.register? ? in2.pr : XZR
          asm.ldp in1.pr, in2, [SP], 16
        else
          asm.add SP, SP, 16
        end
      end

      def put_label label, _, _
        asm.put_label label
      end
    end
  end
end
