# frozen_string_literal: true

require "tenderjit/bitmatrix"
require "tenderjit/adjacency_list"

class TenderJIT
  class InterferenceGraph
    attr_reader :size

    def initialize size
      @size      = size
      @bm        = TenderJIT::BitMatrix.new(size)
      @adjacency = TenderJIT::AdjacencyList.new
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
      @adjacency.neighbors(x)
    end

    def remove x
      @adjacency.neighbors(x).each do |neighbor|
        @bm.unset x, neighbor
      end
      @adjacency.remove x
    end

    def to_dot title, colors = nil
      if colors
        nodes = @adjacency.nodes.map { |i|
          if color = colors[i]
            "#{i} [color=#{color + 1}];"
          end
        }.compact.join("\n")

        "graph g {\n" +
          "label=\"#{title}\";\n" +
          "node[style=\"filled\" colorscheme=\"set19\"];\n" +
          nodes + "\n" + @bm.each_pair.map { |x, y| "#{x} -- #{y};" }.join("\n") + "\n}"
      else
        @bm.to_dot
      end
    end
  end
end
