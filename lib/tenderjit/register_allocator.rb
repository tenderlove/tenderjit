require "set"
require "tenderjit/error"
require "tenderjit/interference_graph"

class TenderJIT
  class RegisterAllocator
    # Maps register classes to colors
    class ColorMap
      def initialize
        @register_classes = {}
        @classes_to_colors = {}
        @reg_lut = [] # maps colors to registers
        @color_lut = [] # maps live ranges to colors
        @interference_classes = {}
      end

      def all_colors
        @reg_lut.compact.map(&:to_i).sort
      end

      def add_overlap c1, c2
        @interference_classes[c1] << c2
        @interference_classes[c2] << c1
      end

      def add_regs klass, regs
        @interference_classes[klass] = [klass]
        @register_classes[klass] = regs
        add_colors klass, regs
        regs.each { |reg| @reg_lut[reg.to_i] = reg }
      end

      def overlap lr
        @interference_classes.fetch(lr.rclass)
      end

      def possible_colors lr
        assigned = assigned_color(lr)
        if assigned
          [assigned]
        else
          @classes_to_colors.fetch(lr.rclass)
        end
      end

      def assign_color lr, this_color
        @color_lut[lr.name] = this_color
      end

      def assigned_color lr
        @color_lut[lr.name]
      end

      def [] i
        @color_lut[i]
      end

      def available_colors klass
        @register_classes.fetch(klass)
      end

      def pr_for lr
        @reg_lut.fetch(assigned_color(lr))
      end

      private

      def add_colors klass, regs
        @classes_to_colors[klass] = regs.map(&:to_i)
      end
    end

    attr_reader :scratch_regs

    def initialize sp, param_regs, scratch_regs, ret
      @parameter_registers = param_regs.dup
      @scratch_regs        = scratch_regs
      @sp                  = sp
      @ret                 = ret
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
      ig = build bbs, live_ranges
      ig.freeze

      # coalesce # FIXME: we should implement coalescing

      color_map = ColorMap.new
      color_map.add_regs :general, @scratch_regs
      color_map.add_regs :sp,      [@sp]
      color_map.add_regs :param,   @parameter_registers
      color_map.add_regs :ret,     [@ret]

      color_map.add_overlap :param, :ret

      # Pre-color parameter registers
      live_ranges.select(&:param?).each do |param|
        color = color_map.possible_colors(param)[param.number]
        color_map.assign_color(param, color)
      end

      stack = simplify ig, live_ranges, color_map
      spills = select ig, stack, color_map

      if $DEBUG
        File.binwrite("if_graph.#{counter}.dot", ig.to_dot("Interference Graph #{counter}", color_map))
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
        live_ranges.each do |lr|
          pr = color_map.pr_for(lr)
          lr.physical_register = pr
          lr.freeze
        end
        false
      end
    end

    private

    ##
    # Insert spills
    def insert_spill spill, counter, ir
      puts "Spilling #{spill}"
      if spill.spill_cost.infinite?
        raise "Can't solve this interference graph"
      end

      spill.spill(ir, counter)
    end

    ##
    # Select. Select registers for each live range.
    def select graph, stack, cm
      spill_list = []

      while lr = stack.shift
        overlaps_with = cm.overlap lr

        # only consider colors of neighbors that compete with this class
        used_colors = graph.neighbors(lr.name).select { |neighbor|
          # Find all neighbors that overlap
          overlaps_with.include?(neighbor.rclass)
        }.flat_map { |neighbor|
          cm.assigned_color(neighbor)
        }.compact

        this_color = (cm.possible_colors(lr) - used_colors).first

        if this_color
          cm.assign_color lr, this_color
        else
          spill_list << lr
        end
      end

      spill_list
    end

    ##
    # Simplify.  Return a stack of live ranges to color
    def simplify graph, lrs, cm
      work_list = lrs.dup
      graph = graph.dup

      stack = []

      loop do
        break if work_list.empty?

        can_push, work_list = work_list.partition { |x|
          graph.degree(x.name) < cm.available_colors(x.rclass).length
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
    def build bbs, live_ranges
      graph = InterferenceGraph.new live_ranges

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

          insn.used_variables.each { |var| live_now << var }
        end
      end

      graph
    end
  end
end
