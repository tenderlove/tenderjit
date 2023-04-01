# frozen_string_literal: true

require "tenderjit/bitmatrix"
require "tenderjit/adjacency_list"

class TenderJIT
  class InterferenceGraph
    attr_reader :size

    def initialize live_ranges
      @live_ranges = live_ranges
      @lr_lut      = live_ranges.each_with_object([]) { |lr, lut| lut[lr.name] = lr }
      @size        = live_ranges.max_by(&:name)&.name.to_i + 1
      @bm          = TenderJIT::BitMatrix.new(@size)
      @adjacency   = TenderJIT::AdjacencyList.new
    end

    def initialize_copy other
      @bm        = @bm.dup
      @adjacency = @adjacency.dup
    end

    def freeze
      @bm.freeze
      @adjacency.freeze
      super
    end

    def add x, y
      return if @bm.set?(x, y)
      @bm.set x, y
      @adjacency.add x, y
    end

    def degree x
      neighbors(x).length
    end

    def neighbors x
      @adjacency.neighbors(x).map { |idx| @lr_lut[idx] }
    end

    def remove x
      @adjacency.neighbors(x).each do |neighbor|
        @bm.unset x, neighbor
      end
      @adjacency.remove x
    end

    def to_dot title, colors = nil
      if colors
        dot_color_map = []
        colors.all_colors.each_with_index { |color, i| dot_color_map[color] = i }

        nodes = @adjacency.nodes.map { |i|
          if color = colors[i]
            color = dot_color_map[color]
            "#{i} [color=#{color + 1}];"
          end
        }.compact.join("\n")

        "graph g {\n" +
          "label=\"#{title}\";\n" +
          "node[style=\"filled\" colorscheme=\"spectral11\"];\n" +
          nodes + "\n" + @bm.each_pair.map { |x, y| "#{x} -- #{y};" }.join("\n") + "\n}"
      else
        @bm.to_dot
      end
    end
  end
end
