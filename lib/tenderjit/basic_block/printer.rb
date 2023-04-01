# frozen_string_literal: true

class TenderJIT
  class BasicBlock
    class Printer
      class Highlighter
        def self.even
          "\033[30;0;0m"
        end

        def self.odd
          "\033[30;0;107m"
        end

        def self.endline
          "\033[0m"
        end
      end

      class None
        def self.even; ""; end
        def self.odd; ""; end
        def self.endline; ""; end
      end

      def initialize bbs
        @bbs = bbs
      end

      def to_dot
        lv_map = live_var_map @bbs

        buf = ""
        buf += "digraph {\n"
        buf += "rankdir=TD; ordering=out;\n"
        buf += "node[shape=box fontname=\"Comic Code\"];\n"
        buf += "edge[fontname=\"Comic Code\"];\n"
        @bbs.each do |block|
          buf += block.name.to_s
          buf += "["
          if block.start.put_label? && block.start.out.name == :exit
            buf += "fontcolor=\"grey\" color=\"grey\" "
          end
          buf += "label=\"BB#{block.name}\\l"
          buf += "UE:       #{vars block.ue_vars}\\l"
          buf += "Killed:   #{vars block.killed_vars}\\l"
          buf += "Live Out: #{vars block.live_out}\\l"
          if block.phis.any?
            block.phis.each do |phi|
              buf += "Phi: #{vars [phi.out]} = "
              buf += "#{vars phi.inputs}\\l"
            end
          end
          buf += "Dom:      #{block.dominators.map(&:name).join(",")}\\l"
          #buf += ir.dump_insns(block.each_instruction.to_a, ansi: false)
          buf += block_text block, lv_map, None
          buf += "\"];\n"
          if bb = block.out1
            buf += "#{block.name} -> #{bb.name} [label=\"out1\"];\n"
          end
          if bb = block.out2
            buf += "#{block.name} -> #{bb.name} [label=\"out2\"];\n"
          end
        end
        buf += "}\n"
        buf
      end

      def to_ascii
        lv_map = live_var_map @bbs
        block_text @bbs, lv_map, Highlighter
      end

      def to_text
        lv_map = live_var_map @bbs
        block_text @bbs, lv_map, None
      end

      private

      def vars set
        set.map(&:to_s).join(", ")
      end

      def block_text bbs, lv_map, highlight
        all_vars = variables bbs, lv_map
        all_vars.sort_by!(&:name)

        var_to_index = all_vars.each_index.with_object({}) { |i, obj|
          obj[all_vars[i]] = i
        }

        widest_var_num = (all_vars.map(&:name).map(&:to_s).max_by(&:length) || []).size + 1

        widest_reg_name = (all_vars.map { |var|
          var.physical_register ? var.physical_register.name : var.name.to_s
        }.max_by(&:length) || []).length + 1

        var_width = [widest_var_num, widest_reg_name].max

        width_matrix = bbs.each_instruction.map { |insn|
          [insn.out, insn.arg1, insn.arg2].map(&:to_s).map(&:length)
        }

        widest_out = width_matrix.map(&:first).max + 1
        widest_arg1 = width_matrix.map { _1[1] }.max + 1
        widest_arg2 = width_matrix.map { _1[2] }.max + 1

        widest_insn_name = bbs.each_instruction.map(&:op).map(&:to_s).max_by(&:length).length + 1

        buf = (["".ljust(widest_insn_name),
               "OUT".ljust(widest_out),
               "IN1".ljust(widest_arg1),
               "IN2".ljust(widest_arg2)] +
        all_vars.map { |x| x.name.to_s.ljust(var_width) }).join + "\n"

        i = 0
        bbs.each_instruction do |insn|
          var_buf = Array.new(all_vars.length) { "".ljust(var_width) }
          live_now = lv_map[insn]
          live_now.each { |live|
            idx = var_to_index[live]
            if live.physical_register
              var_buf[idx] = live.physical_register.name.ljust(var_width)
            else
              var_buf[idx] = "X".ljust(var_width)
            end
          }

          buf += if i.even?
                   highlight.even
                 else
                   highlight.odd
                 end

          buf += ([ insn.op.to_s.ljust(widest_insn_name),
                   insn.out.to_s.ljust(widest_out),
                   insn.arg1.to_s.ljust(widest_arg1),
                   insn.arg2.to_s.ljust(widest_arg2), ] + var_buf).join

          buf += highlight.endline
          buf += "\n"
          i += 1
        end
        buf
      end

      def variables bbs, lv_map
        vars = Set.new
        bbs.each_instruction do |insn|
          vars << insn.set_variable if insn.set_variable
          vars |= lv_map[insn]
        end
        vars.to_a
      end

      ##
      # Returns a hash of live vars for each instruction.  The key is the
      # instruction and the value is a set of live variables
      def live_var_map bbs
        live_var_map = {}

        bbs.head.dfs.reverse_each do |bi|
          live = bi.live_out = bi.successors.inject(Set.new) do |set, succ|
            set | (succ.live_in(bi) | (succ.live_out - succ.killed_vars))
          end

          live_now = live.dup

          bi.reverse_each_instruction do |insn|
            insn.used_variables.each { |var| live_now << var }

            live_var_map[insn] = live_now.dup

            live_now.delete insn.out if insn.out.variable?
          end
        end

        live_var_map
      end
    end
  end
end
