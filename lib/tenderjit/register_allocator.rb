require "set"
require "tenderjit/error"

class TenderJIT
  class RegisterAllocator
    class DoubleFree < Error; end
    class OutsideLiveRange < Error; end

    attr_reader :scratch_regs

    class BorrowedRegister
      attr_reader :info

      def initialize reg, info
        @reg = reg
        @info = info
      end

      def unwrap; @reg; end

      def borrowed?; true; end
    end

    class OwnedRegister
      def initialize reg
        @reg = reg
      end

      def unwrap; @reg; end

      def borrowed?; false; end
    end

    def initialize sp, param_regs, scratch_regs
      @parameter_registers = param_regs.map { |x| OwnedRegister.new(x) }
      @scratch_regs        = Set.new(scratch_regs.map { OwnedRegister.new(_1) })
      @freelist            = @scratch_regs.to_a
      @borrow_list         = []
      @active              = Set.new
      @sp                  = OwnedRegister.new(sp)
    end

    def ensure virt, from, to
      if virt.physical_register
        virt.physical_register
      else
        if virt.stack_pointer?
          virt.physical_register = @sp
        else
          if virt.param?
            virt.physical_register = @parameter_registers[virt.name]
          else
            alloc virt, from, to
          end
        end
      end
    end

    def lend_until phys, i
      @borrow_list << [phys, i]
      false
    end

    def free r, phys
      @active.delete r

      if phys.borrowed?
        @borrow_list << phys.info
        return true
      end

      if @freelist.include?(phys)
        msg = "Physical register #{phys.unwrap.to_i} freed twice"
        raise DoubleFree, msg
      end

      if @scratch_regs.include? phys
        @freelist.push phys
      end

      true
    end

    def spill?; false; end

    def allocate cfg, ir
      active = Set.new

      cfg.dfs do |block|
        block.each_instruction do |insn|
          # vr == "virtual register"
          # pr == "physical register"

          i = insn.number

          vr1 = insn.arg1
          vr2 = insn.arg2
          vr3 = insn.out

          # ensure we have physical registers for the arguments.
          # `ensure` may not return a physical register in the case where
          # the virtual register is actually a label or a literal value
          begin
            active.delete vr1
            active.delete vr2
            active.delete vr3

            active.find_all { |vr|
              vr.free(self, i)
            }.each { |mm| active.delete mm }

            pr1 = vr1.ensure(self, i)
            return Spill.new(vr1, insn, block, @active.dup) if pr1 == SPILL

            pr2 = vr2.ensure(self, i)
            return Spill.new(vr2, insn, block, @active.dup) if pr2 == SPILL

            # Free the physical registers if they're not used after this
            if vr1 == vr2
              active << vr1 unless vr1.free(self, i)
            else
              active << vr2 unless vr2.free(self, i)
              active << vr1 unless vr1.free(self, i)
            end

            # Allocate a physical register for the output virtual register
            pr3 = vr3.ensure(self, i)
            return Spill.new(vr3, insn, block, @active.dup) if pr3 == SPILL

            # Free the output register if it's not used after this
            active << vr3 unless vr3.free(self, i)
          rescue TenderJIT::Error
            puts
            puts cfg.dump_usage i
            raise
          end
        end
      end

      self
    end

    private

    SPILL = false
    private_constant :SPILL

    def alloc r, from, to
      phys = nil
      if !@borrow_list.empty?
        reg_info = @borrow_list.find_all { |_, next_use|
          next_use > to
        }.sort_by { |reg, next_use| next_use - to }.first

        if reg_info
          @borrow_list.delete reg_info
          phys = BorrowedRegister.new(reg_info.first.unwrap, reg_info)
        end
      end

      phys ||= @freelist.pop

      if phys
        r.physical_register = phys
        @active << r
        phys
      else
        SPILL
      end
    end

    class Spill
      attr_reader :var, :insn, :block, :active

      def initialize var, insn, block, active
        @var    = var
        @insn   = insn
        @block  = block
        @active = active
      end

      def spill?; true; end
    end
  end
end
