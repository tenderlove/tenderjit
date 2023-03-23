require "set"
require "tenderjit/error"
require "tenderjit/interference_graph"

class TenderJIT
  class RegisterAllocator
    attr_reader :scratch_regs

    def initialize sp, param_regs, scratch_regs
      @parameter_registers = param_regs.dup
      @scratch_regs        = Set.new(scratch_regs)
      @freelist            = @scratch_regs.to_a
      @borrow_list         = []
      @active              = Set.new
      @sp                  = sp
    end

    def spill?; false; end

    def allocate bbs, ir
      counter = 0
      adjust = 0
      while true
        stack_adjust = doit bbs, ir, counter
        adjust += stack_adjust if stack_adjust
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
        File.binwrite("cfg.#{counter}.dot", BasicBlock::Printer.new(bbs).to_dot)
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
  end
end
