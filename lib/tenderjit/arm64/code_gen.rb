require "aarch64"

class TenderJIT
  module ARM64
    class CodeGen
      def assemble ra, ir
        @asm = AArch64::Assembler.new

        @params = []

        idx = nil
        ir.each_instruction do |insn, i|
          idx = i
          # vr == "virtual register"
          # pr == "physical register"

          vr1 = insn.arg1
          vr2 = insn.arg2
          vr3 = insn.out

          # ensure we have physical registers for the arguments.
          # `ensure` may not return a physical register in the case where
          # the virtual register is actually a label or a literal value
          pr1 = vr1.ensure(ra)
          pr2 = vr2.ensure(ra)

          # Free the physical registers if they're not used after this
          vr2.free(ra, pr2, i)
          vr1.free(ra, pr1, i)

          # Allocate a physical register for the output virtual register
          pr3 = vr3.ensure(ra)

          # Free the output register if it's not used after this
          vr3.free(ra, pr3, i)

          # Convert this SSA instruction to ARM64
          send insn.op, pr3, pr1, pr2
        end

        @asm
      rescue RegisterAllocator::Spill
        ir.dump_usage
        raise
      end

      private

      attr_reader :asm

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
        asm.add out, arg1, arg2
      end

      def sub out, arg1, arg2
        asm.sub out, arg1, arg2
      end

      def return out, arg1, arg2
        if out != AArch64::Registers::X0 || arg1.integer?
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
