# frozen_string_literal: true

class TenderJIT
  ##
  # Lower Triangular Bit Matrix.  This is a bit matrix used for representing
  # undirected graphs.  Only one triangular side of the matrix is used.
  class BitMatrix
    def initialize size
      @size = size
      size = (size + 7) & -8 # round up to the nearest multiple of 8
      @row_bytes = size / 8
      @buffer = "\0".b * (@row_bytes * size)
    end

    def initialize_copy other
      @buffer = @buffer.dup
    end

    def set x, y
      raise IndexError if y >= @size || x >= @size

      x, y = [y, x].sort

      row = x * @row_bytes
      column_byte = y / 8
      column_bit = 1 << (y % 8)

      @buffer.setbyte(row + column_byte, @buffer.getbyte(row + column_byte) | column_bit)
    end

    def unset x, y
      raise IndexError if y >= @size || x >= @size

      x, y = [y, x].sort

      row = x * @row_bytes
      column_byte = y / 8
      column_bit = 1 << (y % 8)

      @buffer.setbyte(row + column_byte, @buffer.getbyte(row + column_byte) & ~column_bit)
    end

    def set? x, y
      raise IndexError if y >= @size || x >= @size

      x, y = [y, x].sort

      row = x * @row_bytes
      column_byte = y / 8
      column_bit = 1 << (y % 8)

      (@buffer.getbyte(row + column_byte) & column_bit) != 0
    end

    def each_pair
      return enum_for(:each_pair) unless block_given?

      @buffer.bytes.each_with_index do |byte, i|
        row = i / @row_bytes
        column = i % @row_bytes
        8.times do |j|
          if (1 << j) & byte != 0
            yield [row, (column * 8) + j]
          end
        end
      end
    end

    def == other
      super || buffer == other.buffer
    end

    def to_dot
      "graph g {\n" + each_pair.map { |x, y| "#{x} -- #{y};" }.join("\n") + "\n}"
    end

    protected

    attr_reader :buffer
  end
end
