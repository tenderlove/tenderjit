require "aarch64"

class TenderJIT
  module ARM64
    class CodeGen
      include AArch64::Registers

      class ZR
        def self.pr
          ::AArch64::Registers::XZR
        end
      end

      attr_reader :asm

      def initialize
        @asm = AArch64::Assembler.new
        @params = []
        @pushes = 0
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

      def int2num dest, in1, _
        asm.lsl dest.pr, in1.pr, 1
        asm.orr dest.pr, dest.pr, 1
      end

      def num2int dest, in1, _
        asm.asr dest.pr, in1.pr, 1
      end

      def shr dest, reg, amount
        asm.asr dest.pr, reg.pr, amount.pr
      end

      def shl dest, reg, amount
        asm.lsl dest.pr, reg.pr, amount.pr
      end

      def jz dest, arg1, _
        je dest, arg1, ZR
      end

      def jnz dest, arg1, _
        jne dest, arg1, ZR
      end

      def jle dest, arg1, arg2
        cmp nil, arg1, arg2
        asm.b dest.pr, cond: :le
      end

      def jgt dest, arg1, arg2
        cmp nil, arg1, arg2
        asm.b dest.pr, cond: :gt
      end

      def jne dest, arg1, arg2
        cmp nil, arg1, arg2
        asm.b dest.pr, cond: :ne
      end

      def tbnz dest, arg1, arg2
        asm.tbnz arg1.pr, arg2.pr, dest.pr
      end

      def je dest, arg1, arg2
        cmp nil, arg1, arg2
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

      def or out, arg1, arg2
        asm.orr out.pr, arg1.pr, arg2.pr
      end

      def and out, arg1, arg2
        raise if arg1.immediate?

        asm.and out.pr, arg1.pr, arg2.pr
      end

      def add out, arg1, arg2
        if arg1.immediate?
          arg1, arg2 = arg2, arg1
        end

        asm.adds out.pr, arg1.pr, arg2.pr
      end

      def mul out, arg1, arg2
        asm.mul out.pr, arg1.pr, arg2.pr
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
        if offset.immediate?
          asm.ldur out.pr, [src.pr, offset.pr]
        else
          asm.ldr out.pr, [src.pr, offset.pr]
        end
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

      def csel_eq out, in1, in2
        in2 = in2.pr == 0 ? XZR : in2.pr
        asm.csel out.pr, in1.pr, in2, :eq
      end

      def csel_lt out, in1, in2
        in2 = in2.pr == 0 ? XZR : in2.pr
        asm.csel out.pr, in1.pr, in2, :lt
      end

      def csel_gt out, in1, in2
        in2 = in2.pr == 0 ? XZR : in2.pr
        asm.csel out.pr, in1.pr, in2, :gt
      end

      def stack_alloc _, amount, _
        asm.sub SP, SP, amount.pr
      end

      def stack_free _, amount, _
        asm.add SP, SP, amount.pr
      end

      def store_spill _, reg, off
        asm.str reg.pr, [SP, (off.pr + @pushes) * Fiddle::SIZEOF_VOIDP]
      end

      def load_spill out, off, _
        asm.ldr out.pr, [SP, (off.pr + @pushes) * Fiddle::SIZEOF_VOIDP]
      end

      def push out, in1, in2
        @pushes += 2
        in1 = in1.register? ? in1.pr : XZR
        in2 = in2.register? ? in2.pr : XZR
        asm.stp in1, in2, [SP, -16], :!
      end

      def pop out, in1, in2
        @pushes -= 2
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
