require "aarch64"

class TenderJIT
  module ARM64
    class CodeGen
      def assemble ra, ir
        asm = AArch64::Assembler.new

        ir.instructions.each_with_index do |insn, i|
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
          vr1.free(ra, pr1, i)
          vr2.free(ra, pr2, i)

          # Allocate a physical register for the output virtual register
          pr3 = vr3.ensure(ra)

          # Free the output register if it's not used after this
          vr3.free(ra, pr3, i)

          # Convert this SSA instruction to ARM64
          send insn.op, asm, pr3, pr1, pr2, i
        end

        asm
      end

      private

      def jle asm, dest, arg1, arg2, i
        asm.cmp arg1, arg2.value
        asm.b dest, cond: :le
      end

      def neg asm, out, arg1, _, _
        asm.neg out, arg1
      end

      def and asm, out, arg1, arg2, _
        asm.and out, arg1, arg2
      end

      def add asm, out, arg1, arg2, _
        asm.add out, arg1, arg2
      end

      def return asm, out, arg1, arg2, _
        if out != AArch64::Registers::X0
          arg1 = arg1.value unless arg1.register?

          asm.mov AArch64::Registers::X0, arg1
        end

        asm.ret
      end

      def load asm, out, src, offset, _
        asm.ldr out, [src, offset.value]
      end

      def write asm, out, _, val, _
        asm.mov out, val.value
      end

      def brk asm, _, _, _, i
        asm.brk 1
      end

      def jmp asm, out, arg1, _, i
        asm.b arg1
      end

      def put_label asm, _, label, _, _
        asm.put_label label
      end
    end
  end
end
