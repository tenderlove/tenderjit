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

          if vr1.register?
            pr1 = ra.ensure vr1
          else
            pr1 = vr1
          end

          if vr2.register?
            pr2 = ra.ensure vr2
          else
            pr2 = vr2
          end

          ra.free pr1 if vr1.register? && !vr1.used_after(i)
          ra.free pr2 if vr2.register? && !vr2.used_after(i)

          pr3 = ra.alloc vr3

          ra.free pr3 if vr3.register? && !vr3.used_after(i)

          send insn.op, asm, pr3, pr1, pr2, i
        end

        asm
      end

      private

      def add asm, out, arg1, arg2, _
        asm.add out, arg1, arg2
      end

      def return asm, out, arg1, arg2, _
        if out != AArch64::Registers::X0
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
