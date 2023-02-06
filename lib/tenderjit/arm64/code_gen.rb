require "aarch64"

class TenderJIT
  module ARM64
    class CodeGen
      attr_reader :asm

      def initialize
        @asm = AArch64::Assembler.new
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

      def jle dest, arg1, arg2
        asm.cmp arg1, arg2
        asm.b dest, cond: :le
      end

      def jne dest, arg1, arg2
        asm.cmp arg1, arg2
        asm.b dest, cond: :ne
      end

      def tbnz dest, arg1, arg2
        asm.tbz arg1, arg2, dest
      end

      def je dest, arg1, arg2
        asm.cmp arg1, arg2
        asm.b dest, cond: :eq
      end

      def neg out, arg1, _
        asm.neg out, arg1
      end

      def call _, location, arity
        @params.pop(arity).each_with_index do |param, i|
          param_reg = PARAM_REGS[i]
          if param != param_reg
            asm.mov param_reg, param
          end
        end
        asm.stur AArch64::Registers::X30, [AArch64::Registers::SP, -16]
        asm.blr location
        asm.ldur AArch64::Registers::X30, [AArch64::Registers::SP, -16]
      end

      def and out, arg1, arg2
        asm.and out, arg1, arg2
      end

      def add out, arg1, arg2
        if arg1.integer?
          asm.mov out, arg1
          asm.add out, out, arg2
          return
        end

        if arg2.integer?
          asm.mov out, arg2
          asm.add out, out, arg1
          return
        end

        asm.add out, arg1, arg2
      end

      def sub out, arg1, arg2
        asm.sub out, arg1, arg2
      end

      def return _, arg1, _
        if arg1 != AArch64::Registers::X0 || arg1.integer?
          asm.mov AArch64::Registers::X0, arg1
        end

        asm.ret
      end

      def store offset, val, dst
        asm.stur val, [dst, offset]
      end

      def load out, src, offset
        asm.ldur out, [src, offset]
      end

      def write out, _, val
        if val.integer?
          asm.movz out, val & 0xFFFF
          val >>= 16
          shift = 16
          while val > 0
            asm.movk out, val & 0xFFFF, lsl: shift
            val >>= 16
            shift <<= 1
          end
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

      def jmp out, arg1, _
        asm.b arg1
      end

      def put_label _, label, _
        asm.put_label label
      end
    end
  end
end
