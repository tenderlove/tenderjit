require "set"
require "tenderjit/error"
require "tenderjit/interference_graph"

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

    def allocate bbs, ir
      counter = 0
      adjust = 0
      while true
        stack_adjust = doit bbs, ir, counter
        adjust += stack_adjust if stack_adjust
        if $DEBUG
          BasicBlock.number bbs
          File.binwrite("after_spill.#{counter}.dot", CFG.new(bbs, ir).to_dot)
        end
        counter += 1
        raise "FIXME!" if counter > 7
        break unless stack_adjust
      end
      adjust
    end

    def doit bbs, ir, counter
      live_ranges = renumber bbs
      ig = build bbs, live_ranges.last.name + 1
      ig.freeze
      # coalesce
      stack = simplify ig, live_ranges, @scratch_regs.length
      lr_colors, spills = select ig, stack, @scratch_regs.length.times.to_a

      if $DEBUG
        File.binwrite("if_graph.#{counter}.dot", ig.to_dot("Interference Graph #{counter}", lr_colors))
      end

      stack_adjust = 0
      if spills.any?
        # Eagerly spill negative regs
        cheap_spills = live_ranges.find_all { |x| x.spill_cost < 0 }
        if cheap_spills.length > 0
          cheap_spills.each { |spill| stack_adjust += insert_spill(spill, counter, ir) }
        else
          spill = spills.first
          # If we couldn't find a good spill, try spilling anything cheap
          if spill.spill_cost.infinite?
            spill = live_ranges.sort_by(&:spill_cost).first
          end

          stack_adjust += insert_spill spill, counter, ir
        end
        stack_adjust
      else
        regs = @scratch_regs.to_a
        live_ranges.each do |lr|
          lr.physical_register = regs[lr_colors[lr.name]]
          lr.freeze
        end
        false
      end
    end

    private

    ##
    # Insert spills
    def insert_spill spill, counter, ir
      if spill.spill_cost.infinite?
        raise "Can't solve this interference graph"
      end

      spill.spill(ir, counter)
    end

    ##
    # Select. Select registers for each live range.
    def select graph, stack, colors
      # the index in lr_colors maps to the live range id
      lr_colors = []
      spill_list = []

      while lr = stack.shift
        used_colors = graph.neighbors(lr.name).map { |neighbor|
          lr_colors[neighbor]
        }.compact
        this_color = (colors - used_colors).first
        if this_color
          lr_colors[lr.name] = this_color
        else
          spill_list << lr
        end
      end
      [lr_colors, spill_list]
    end

    ##
    # Simplify.  Return a stack of live ranges to color
    def simplify graph, lrs, reg_count
      work_list = lrs.dup
      graph = graph.dup

      stack = []

      loop do
        break if work_list.empty?

        can_push, work_list = work_list.partition { |x|
          graph.degree(x.name) < reg_count
        }

        can_push.each { |lr| graph.remove(lr.name) }

        stack.concat can_push

        if can_push.empty?
          work_list.sort_by!(&:spill_cost)
          range = work_list.shift
          graph.remove(range.name)
          stack << range
        end
      end

      stack
    end

    ##
    # Find all distinct live ranges and number them uniquely
    def renumber bbs
      # Combine Live ranges for PHIs
      phis = bbs.flat_map(&:phis)
      phis.each { |phi|
        lr = CombinedLiveRange.new(phi.arg1, phi.arg2, phi.out)
        phi.arg1.live_range = lr
        phi.arg2.live_range = lr
        phi.out.live_range = lr
      }
      lrs = bbs.flat_map(&:killed_vars).map(&:live_range)
      lrs.sort_by!(&:name)
      lrs
    end

    ##
    # Build the interference graph
    def build bbs, lr_size
      graph = InterferenceGraph.new lr_size

      bbs.dfs.reverse_each do |bi|
        live = bi.live_out = bi.successors.inject(Set.new) do |set, succ|
          set | (succ.live_in(bi) | (succ.live_out - succ.killed_vars))
        end

        live_now = Set.new(live.map(&:live_range))

        bi.reverse_each_instruction do |insn|
          live_now.delete insn.lr_out if insn.out.variable?

          if insn.out.variable?
            live_now.each do |ln|
              x, y = ln.name, insn.lr_out.name
              graph.add(x, y)
            end
          end

          live_now << insn.arg1.live_range if insn.arg1.variable?
          live_now << insn.arg2.live_range if insn.arg2.variable?
        end
      end

      graph
    end

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
