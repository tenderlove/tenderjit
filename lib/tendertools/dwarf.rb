# frozen_string_literal: true

require "tendertools/dwarf/constants"

module TenderTools
module DWARF
  module Constants
    TAG_TO_NAME = constants.grep(/TAG/).each_with_object([]) { |c, o|
      v = const_get(c)
      if v < DW_TAG_low_user
        o[const_get(c)] = c
      end
    }

    def self.tag_for id
      TAG_TO_NAME[id]
    end

    def self.at_for id
      constants.grep(/_AT_/).find { |c| const_get(c) == id }
    end

    def self.form_for id
      constants.grep(/_FORM_/).find { |c| const_get(c) == id }
    end
  end

  class Tag
    attr_reader :index, :type

    def self.build index, type, has_children, attr_names, attr_forms
      new index, type, has_children, attr_names, attr_forms
    end

    def initialize index, type, has_children, attr_names, attr_forms
      @index        = index
      @type         = type
      @has_children = has_children
      @attr_names   = attr_names
      @attr_forms   = attr_forms
    end

    class_eval Constants.constants.grep(/^DW_TAG_(.*)$/) { |match|
      "def #{$1}?; type == Constants::#{match}; end"
    }.join "\n"

    def has_children?; @has_children; end

    def identifier
      Constants.tag_for(@type)
    end

    def attribute_info name
      i = index_of(name) || return
      yield @attr_forms, i
    end

    def index_of name
      @attr_names.index(name)
    end

    def decode io, _
      @attr_forms.map do |type|
        case type
        when Constants::DW_FORM_addr
          io.read(8).unpack1("Q")
        when Constants::DW_FORM_strp
          io.read(4).unpack1("L")
        when Constants::DW_FORM_data1
          io.read(1).unpack1("C")
        when Constants::DW_FORM_data2
          io.read(2).unpack1("S")
        when Constants::DW_FORM_data4
          io.read(4).unpack1("L")
        when Constants::DW_FORM_data8
          io.read(8).unpack1("Q")
        when Constants::DW_FORM_sec_offset
          io.read(4).unpack1("L")
        when Constants::DW_FORM_ref_addr
          io.read(4).unpack1("L")
        when Constants::DW_FORM_ref4
          io.read(4).unpack1("L")
        when Constants::DW_FORM_flag_present
          true
        when Constants::DW_FORM_exprloc
          io.read(DWARF.unpackULEB128(io))
        when Constants::DW_FORM_string
          str = []
          loop do
            x = io.readbyte
            break if x == 0
            str << x
          end

          str.pack("C*")
        when Constants::DW_FORM_flag
          io.readbyte
        when Constants::DW_FORM_block1
          io.read io.readbyte
        when Constants::DW_FORM_udata
          DWARF.unpackULEB128 io
        when Constants::DW_FORM_sdata
          DWARF.unpackSLEB128 io
        else
          raise "Unhandled type: #{Constants.form_for(type)}"
        end
      end
    end

    def inspect
      names = @attr_names.map { |k| Constants.at_for(k) || :Custom }
      forms = @attr_forms.map { |v| Constants.form_for(v) }
      maxlen = names.map { |x| x.length }.max || 0

      "[#{@index}] #{Constants.tag_for(@type)} #{@has_children ? "children" : "no children"}\n" +
        names.zip(forms).map { |k,v| "        #{k.to_s.ljust(maxlen)} #{v}" }.join("\n")

    end
  end

  class DebugStrings
    def initialize io, section, head_pos
      @io      = io
      @section = section
      @head_pos = head_pos
    end

    def string_at offset
      pos = @io.pos
      @io.seek @head_pos + @section.offset + offset, IO::SEEK_SET
      @io.readline("\x00").b.delete("\x00")
    ensure
      @io.seek pos, IO::SEEK_SET
    end
  end

  class DIE
    include Enumerable

    attr_reader :tag, :offset, :attributes, :children

    def initialize tag, offset, attributes, children
      @tag        = tag
      @offset     = offset
      @attributes = attributes
      @children   = children
    end

    def find_type child
      raise ArgumentError, "DIE doesn't have a type" unless child.type
      children.bsearch { |c_die| child.type <=> c_die.offset }
    end

    def location
      at Constants::DW_AT_location
    end

    def low_pc
      at Constants::DW_AT_low_pc
    end

    def high_pc
      at Constants::DW_AT_high_pc
    end

    def data_member_location
      at Constants::DW_AT_data_member_location
    end

    def byte_size
      at Constants::DW_AT_byte_size
    end

    def type
      at Constants::DW_AT_type
    end

    def decl_file
      at Constants::DW_AT_decl_file
    end

    def const_value
      at Constants::DW_AT_const_value
    end

    def name strings
      tag.attribute_info(Constants::DW_AT_name) do |form, i|
        if form == Constants::DW_FORM_string
          attributes[i]
        else
          strings.string_at(attributes[i])
        end
      end
    end

    def name_offset
      at Constants::DW_AT_name
    end

    def each &block
      yield self
      children.each { |child| child.each(&block) }
    end

    def each_with_parents &block
      iter_with_stack([], &block)
    end

    protected

    def iter_with_stack stack, &block
      yield self, stack
      stack.push self
      children.each { |child| child.iter_with_stack(stack, &block) }
      stack.pop
    end

    private

    def at name
      idx = tag.index_of(name)
      idx && attributes[idx]
    end
  end

  class DebugLine
    def initialize io, section, debug_abbrev, head_pos
      @io         = io
      @section    = section
      @head_pos   = head_pos
      @debug_abbrev = debug_abbrev
    end

    def process
      @io.seek @head_pos + @section.offset, IO::SEEK_SET
      while @io.pos < @head_pos + @section.offset + @section.size
        unit_length, dwarf_version = @io.read(6).unpack("LS")
        if dwarf_version != 4
          raise NotImplementedError, "Only DWARF4 rn #{dwarf_version}"
        end
        p unit_length.to_s(16)
        p dwarf_version.to_s(16)

        # we're just not handling 32 bit
        prologue_length,
          min_inst_length,
          max_ops_per_inst,
          default_is_stmt,
          line_base,
          line_range,
          opcode_base = @io.read(4 + (1 * 6)).unpack("LCCCcCC")

        puts prologue_length.to_s(16)
        puts min_inst_length
        puts max_ops_per_inst
        puts default_is_stmt
        puts line_base
        puts line_range
        puts base: opcode_base

        #standard_opcode_lengths = @io.read(opcode_base - 1).bytes
        @io.read(opcode_base - 1)
        include_directories = []

        loop do
          str = @io.readline("\0").chomp("\0")
          break if "" == str
          include_directories << str
        end

        loop do
          fname = @io.readline("\0").chomp("\0")
          break if "" == fname
          p fname
          p DWARF.unpackULEB128 @io
          p DWARF.unpackULEB128 @io
          p DWARF.unpackULEB128 @io
        end
        exit
      end
    end
  end

  CompilationUnit = Struct.new(:unit_length, :version, :debug_abbrev_offset, :address_size, :die)

  class DebugInfo
    def initialize io, section, head_pos
      @io           = io
      @section      = section
      @head_pos     = head_pos
    end

    def compile_units tags
      cus = []
      #@io.seek @head_pos + @section.offset, IO::SEEK_SET
      @io.seek @head_pos + @section.offset, IO::SEEK_SET
      while @io.pos < @head_pos + @section.offset + @section.size
        unit_length, dwarf_version = @io.read(6).unpack("LS")
        if dwarf_version != 4
          raise NotImplementedError, "Only DWARF4 rn #{dwarf_version}"
        end

        debug_abbrev_offset = @io.read(4).unpack1("L")
        address_size = @io.readbyte
        if address_size != 8
          raise NotImplementedError, "only 8 bytes address size supported rn"
        end
        offset = @io.pos - @section.offset
        abbrev_code = DWARF.unpackULEB128 @io
        tag = tags[abbrev_code - 1]
        cu = CompilationUnit.new(unit_length,
                                   dwarf_version,
                                   debug_abbrev_offset,
                                   address_size,
                                   parse_die(@io, tags, tag, offset, address_size))
        cus << cu
      end
      cus
    ensure
      @io.seek @head_pos, IO::SEEK_SET
    end

    private

    def read_children io, tags, address_size
      children = []
      loop do
        offset = io.pos - @section.offset
        abbrev_code = DWARF.unpackULEB128 io

        return children if abbrev_code == 0

        tag = tags.fetch(abbrev_code - 1)
        die = parse_die io, tags, tag, offset, address_size
        children << die
      end
    end

    NO_CHILDREN = [].freeze

    def parse_die io, tags, tag, offset, address_size
      attributes = decode tag, address_size, io

      children = if tag.has_children?
        read_children io, tags, address_size
      else
        NO_CHILDREN
      end
      DIE.new tag, offset - @head_pos, attributes, children
    end

    def decode tag, address_size, io
      tag.decode io, address_size
    end
  end

  class DebugAbbrev
    def initialize io, section, head_pos
      @io      = io
      @section = section
      @head_pos     = head_pos
    end

    def tags
      @tags ||= begin
                  @io.seek @head_pos + @section.offset, IO::SEEK_SET
                  tags = []
                  loop do
                    break if @io.pos + 1 >= @head_pos + @section.offset + @section.size
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
      attr_names = []
      attr_forms = []
      loop do
        attr_name = DWARF.unpackULEB128 @io
        attr_form = DWARF.unpackULEB128 @io
        break if attr_name == 0 && attr_form == 0

        attr_names << attr_name
        attr_forms << attr_form
      end
      Tag.build abbreviation_code, name, children_p, attr_names, attr_forms
    end
  end

  def self.unpackULEB128 io
    result = 0
    shift = 0

    loop do
      byte = io.getbyte
      result |= ((byte & 0x7F) << shift)
      if (byte < 0x80)
        break
      end
      shift += 7
    end

    result
  end

  def self.unpackSLEB128 io
    result = 0
    shift = 0
    size = 64

    loop do
      byte = io.getbyte
      result |= ((byte & 0x7F) << shift)
      shift += 7
      if (byte >> 7) == 0
        if shift < size && byte & 0x40
          result |= (~0 << shift)
        end
        break
      end
    end
    result
  end
end
end
