require "dwarf/constants"

module DWARF
  module Constants
    def self.tag_for id
      constants.grep(/TAG/).find { |c| const_get(c) == id }
    end

    def self.at_for id
      constants.grep(/_AT_/).find { |c| const_get(c) == id }
    end

    def self.form_for id
      constants.grep(/_FORM_/).find { |c| const_get(c) == id }
    end
  end

  class Tag
    def initialize index, name, has_children, attributes
      @index        = index
      @name         = name
      @has_children = has_children
      @attributes   = attributes
    end

    def inspect
      names = @attributes.map { |k,v|
        [Constants.at_for(k) || :Custom, Constants.form_for(v)]
      }
      maxlen = names.sort_by { |x| x.first.length }.last.first.length

      "[#{@index}] #{Constants.tag_for(@name)} #{@has_children ? "children" : "no children"}\n" +
        names.map { |k,v| "        #{k.to_s.ljust(maxlen)} #{v}" }.join("\n")

    end
  end

  class DebugAbbrev
    def initialize io, section
      @io      = io
      @section = section
    end

    def tags
      @tags ||= begin
                  @io.seek @section.offset, IO::SEEK_SET
                  tags = []
                  loop do
                    break if @io.pos + 1 >= @section.offset + @section.size
                    tags << read_tag
                  end
                  tags
                end
    end

    private

    def read_tag
      abbreviation_code = DWARF.unpackULEB128 @io
      name              = DWARF.unpackULEB128 @io
      children_p        = @io.readbyte == Constants::DW_CHILDREN_yes
      attributes = []
      loop do
        attr_name = DWARF.unpackULEB128 @io
        attr_form = DWARF.unpackULEB128 @io
        break if attr_name == 0 && attr_form == 0

        attributes << [attr_name, attr_form]
      end
      Tag.new abbreviation_code, name, children_p, attributes
    end
  end

  def self.unpackULEB128 io
    result = 0
    shift = 0
    loop do
      byte = io.getbyte
      result |= ((byte & 0x7F) << shift)
      if (byte & 0x80) != 0x80
        return result
      end
      shift += 7
    end
  end
end
