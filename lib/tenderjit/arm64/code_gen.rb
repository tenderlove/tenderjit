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

          pr1 = ra.ensure vr1

          if vr2.immediate?
            pr2 = vr2
          else
            pr2 = ra.ensure vr2
          end

          ra.free pr1 unless vr1.used_after(i)
          ra.free pr2 unless vr2.immediate? || vr2.used_after(i)

          pr3 = ra.alloc insn.out

          send insn.op, asm, pr3, pr1, pr2
        end

        asm
      end

      private

      def add asm, out, arg1, arg2
        asm.add out, arg1, arg2
      end

      def return asm, out, arg1, arg2
        if out != AArch64::Registers::X0
          asm.mov AArch64::Registers::X0, arg1
        end

        asm.ret
      end

      def load asm, out, src, offset
        asm.ldr out, [src, offset.value]
      end
    end
  end
end
