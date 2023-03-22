# frozen_string_literal: true

class TenderJIT
  class AdjacencyList
    NONE = [].freeze

    def initialize
      @list = []
    end

    def add x, y
      @list[x] ||= []
      @list[x] << y
      @list[x].sort!
      @list[y] ||= []
      @list[y] << x
      @list[y].sort!
    end

    def nodes
      @list.each_index.find_all { |i| @list[i] }
    end

    def neighbors x
      @list[x] || NONE
    end

    def remove x
      neighbors(x).each do |y|
        @list[y].delete x
      end
      @list[x] = nil
    end

    def initialize_copy other
      @list = @list.map(&:dup)
    end

    def freeze
      @list.each(&:freeze)
      @list.freeze
    end

    def == other
      super || (@list.length == other.list.length &&
        @list.each_with_index.all? { |item, i| item == other.list[i] })
    end

    protected

    attr_reader :list
  end
end
