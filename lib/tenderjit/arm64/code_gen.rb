require "aarch64"

class TenderJIT
  module ARM64
    class CodeGen
      def assemble ra, ir
        @asm = AArch64::Assembler.new

        ir.each_instruction do |insn, i|
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
      end

      private

      attr_reader :asm

      def jle dest, arg1, arg2
        asm.cmp arg1, arg2
        asm.b dest, cond: :le
      end

      def neg out, arg1, _
        asm.neg out, arg1
      end

      def and out, arg1, arg2
        asm.and out, arg1, arg2
      end

      def add out, arg1, arg2
        asm.add out, arg1, arg2
      end

      def return out, arg1, arg2
        if out != AArch64::Registers::X0 || arg1.integer?
          asm.mov AArch64::Registers::X0, arg1
        end

        asm.ret
      end

      def store val, dst, offset
        asm.stur val, [dst, offset]
      end

      def load out, src, offset
        asm.ldur out, [src, offset]
      end

      def write out, m, val
        asm.mov out, val
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
