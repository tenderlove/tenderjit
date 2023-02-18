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
        send insn.op, out, in1, in2
      end

      private

      def set_param _, arg1, _
        @params << arg1
      end

      def tbz dest, reg, bit
        asm.tbz reg, bit, dest
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
        asm.tbnz arg1, arg2, dest
      end

      def je dest, arg1, arg2
        asm.cmp arg1, arg2
        asm.b dest, cond: :eq
      end

      def neg out, arg1, _
        asm.neg out, arg1
      end

      def call _, location, arity
        save_regs = [ X30 ]
        params = @params.pop arity

        mov_regs = []

        params.each_with_index do |param, i|
          param_reg = PARAM_REGS[i]
          if param == param_reg
            # great, don't need to save
          else
            save_regs << param_reg
            mov_regs << [param_reg, param]
          end
        end

        # Save these regs
        save_regs.each_slice(2) do |a, b|
          b ||= XZR
          asm.stp a, b, [SP, -16], :!
        end

        # Write the params
        mov_regs.each do |a|
          asm.mov a.first, a.last
        end

        asm.blr location
        save_regs.each_slice(2).to_a.reverse.each do |a, b|
          b ||= XZR
          asm.ldp a, b, [SP], 16
        end
      end

      def and out, arg1, arg2
        if arg1.integer? && arg2.integer?
          asm.movk(out, arg1 & arg2)
        else
          if arg1.integer?
            asm.movk(out, arg1)
            arg1 = out
          end

          if arg2.integer?
            asm.movk(out, arg2)
            arg2 = out
          end

          asm.and out, arg1, arg2
        end
      end

      def add out, arg1, arg2
        if arg1.integer?
          arg1, arg2 = arg2, arg1
        end

        asm.adds out, arg1, arg2
      end

      def sub out, arg1, arg2
        if arg1.integer? && arg2.integer?
          asm.movz out, arg1 - arg2
          return
        else
          if arg1.integer?
            raise
          end
        end

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
          if val == 0
            asm.mov out, XZR
          else
            asm.movz out, val & 0xFFFF
            val >>= 16
            shift = 1
            while val > 0
              asm.movk out, val & 0xFFFF, lsl: (shift * 16)
              val >>= 16
              shift += 1
            end
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

      def jmp out, _, _
        asm.b out
      end

      def jo dest, _, _
        asm.b dest, cond: :vs
      end

      def cmp _, in1, in2
        asm.cmp in1, in2
      end

      def csel_lt out, in1, in2
        in2 = XZR if in2 == 0
        asm.csel out, in1, in2, :lt
      end

      def put_label label, _, _
        asm.put_label label
      end
    end
  end
end
