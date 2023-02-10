require "set"

class TenderJIT
  class RegisterAllocator
    class Error < StandardError; end
    class Spill < Error; end
    class DoubleFree < Error; end

    attr_reader :scratch_regs

    def initialize param_regs, scratch_regs
      @parameter_registers = param_regs
      @scratch_regs        = Set.new(scratch_regs)
      @freelist            = @scratch_regs.to_a
    end

    def ensure virt
      if virt.physical_register
        virt.physical_register
      else
        if virt.param?
          virt.physical_register = @parameter_registers[virt.name]
        else
          alloc virt
        end
      end
    end

    def alloc r
      phys = @freelist.pop
      if phys
        r.physical_register = phys
      else
        raise Spill, "Spill!"
      end
    end

    def free phys
      raise DoubleFree, "Don't free registers twice!" if @freelist.include?(phys)

      if @scratch_regs.include? phys
        @freelist.push phys
      end
    end

    def assemble ir, asm
      ir.each_instruction do |insn, i|
        # vr == "virtual register"
        # pr == "physical register"

        vr1 = insn.arg1
        vr2 = insn.arg2
        vr3 = insn.out

        # ensure we have physical registers for the arguments.
        # `ensure` may not return a physical register in the case where
        # the virtual register is actually a label or a literal value
        begin
          pr1 = vr1.ensure(self)
          pr2 = vr2.ensure(self)

          # Free the physical registers if they're not used after this
          vr2.free(self, pr2, i)
          vr1.free(self, pr1, i)

          # Allocate a physical register for the output virtual register
          pr3 = vr3.ensure(self)

          # Free the output register if it's not used after this
          vr3.free(self, pr3, i)
        rescue RegisterAllocator::Spill, FrozenError
          ir.dump_usage i
          raise
        end

        # Convert this SSA instruction to machine code
        asm.handle insn, pr3, pr1, pr2
      end
      asm
    end
  end
end
