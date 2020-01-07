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
    attr_reader :index, :name, :attributes

    def initialize index, name, has_children, attributes
      @index        = index
      @name         = name
      @has_children = has_children
      @attributes   = attributes
    end

    def has_children?; @has_children; end

    def inspect
      names = @attributes.map { |k,v|
        [Constants.at_for(k) || :Custom, Constants.form_for(v)]
      }
      maxlen = names.sort_by { |x| x.first.length }.last.first.length

      "[#{@index}] #{Constants.tag_for(@name)} #{@has_children ? "children" : "no children"}\n" +
        names.map { |k,v| "        #{k.to_s.ljust(maxlen)} #{v}" }.join("\n")

    end
  end

  class DebugStrings
    def initialize io, section
      @io      = io
      @section = section
    end

    def string_at offset
      pos = @io.pos
      @io.seek @section.offset + offset, IO::SEEK_SET
      @io.readline("\x00").delete("\x00")
    ensure
      @io.seek pos, IO::SEEK_SET
    end
  end

  class DIE
    attr_reader :tag, :attribute, :children

    def initialize tag, attributes, children
      @tag        = tag
      @attributes = attributes
      @children   = children
    end
  end

  class DebugInfo
    def initialize io, section, debug_abbrev
      @io           = io
      @section      = section
      @debug_abbrev = debug_abbrev
    end

    def compile_units
      pos = @io.pos
      tags = @debug_abbrev.tags

      cus = []
      @io.seek @section.offset, IO::SEEK_SET
      while @io.pos < @section.offset + @section.size
        unit_length = @io.read(4).unpack1("L")
        dwarf_version = @io.read(2).unpack1("S")
        if dwarf_version != 4
          raise NotImplementedError, "Only DWARF4 rn"
        end

        debug_abbrev_offset = @io.read(4).unpack1("L")
        address_size = @io.readbyte
        abbrev_code = DWARF.unpackULEB128 @io
        tag = tags[abbrev_code - 1]
        cus << parse_die(@io, tags, tag, address_size)
      end
      cus
    ensure
      @io.seek pos, IO::SEEK_SET
    end

    private

    def read_children io, tags, address_size
      children = []
      loop do
        abbrev_code = DWARF.unpackULEB128 io

        return children if abbrev_code == 0

        tag = tags[abbrev_code - 1]
        die = parse_die io, tags, tag, address_size
        children << die
      end
    end

    def parse_die io, tags, tag, address_size
      attributes = decode tag, address_size, io

      children = if tag.has_children?
        read_children io, tags, address_size
      else
        []
      end
      DIE.new tag, attributes, children
    end

    def decode tag, address_size, io
      tag.attributes.map do |name, type|
        case type
        when Constants::DW_FORM_strp
          # p strings.string_at io.read(4).unpack1("L")
          io.read(4).unpack1("L")
        when Constants::DW_FORM_data1
          io.readbyte
        when Constants::DW_FORM_data2
          io.read(2).unpack1("S")
        when Constants::DW_FORM_data4
          io.read(4).unpack1("L")
        when Constants::DW_FORM_sec_offset
          io.read(4).unpack1("L")
        when Constants::DW_FORM_flag_present
          true
        when Constants::DW_FORM_addr
          io.read(address_size).unpack1("Q")
        when Constants::DW_FORM_exprloc
          io.read(DWARF.unpackULEB128(io))
        when Constants::DW_FORM_ref4
          io.read(4).unpack1("L")
        else
          raise "Unhandled type: #{Constants.form_for(type)}"
        end
      end
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
