require "tenderjit/ruby_internals"
require "erb"

module Layout
  class CObject < Struct.new(:name, :aliases, :children)
    def has_bitfields?; children.any?(&:bitfield?); end
    def has_autorefs?; children.any?(&:autoref?); end
    def bitfields; children.select(&:bitfield?); end
    def autorefs; children.select(&:autoref?); end

    def anonymous?
      name == "__anonymous"
    end
  end

  class CStruct < CObject; end
  class CUnion < CObject; end

  BasicType   = Struct.new(:name, :fiddle_type)
  ArrayType   = Struct.new(:type, :len)

  class Member < Struct.new(:name, :offset, :type)
    def bitfield?; false; end
    def autoref?; false; end
  end

  class AutoRefMember < Struct.new(:name, :ref_name, :offset, :type)
    def bitfield?; false; end
    def autoref?; true; end
  end

  class SubStruct < Struct.new(:name, :offset, :type)
    def bitfield?; false; end
    def autoref?; false; end

    def name
      [super, type.children.map(&:name)]
    end
  end

  class SubUnion < Struct.new(:name, :offset, :type)
    def bitfield?; false; end
    def autoref?; false; end

    def name
      [super, type.children.map(&:name)]
    end
  end

  class BitMember < Struct.new(:offset, :type, :children)
    def bitfield?; true; end
    def autoref?; false; end

    def name; children.map(&:name).join("|"); end
    def d4?; children.all?(&:d4?); end
  end

  class D4BitMember < Struct.new(:name, :offset, :type, :die)
    def bitfield?; true; end
    def d4?; true; end
  end
  class D5BitMember < Struct.new(:name, :offset, :type, :die)
    def bitfield?; true; end
    def d4?; false; end
  end

  DWARF_TO_FIDDLE = {
    "int"                    => Fiddle::TYPE_INT,
    "char"                   => Fiddle::TYPE_CHAR,
    "signed char"            => Fiddle::TYPE_CHAR,
    "short"                  => Fiddle::TYPE_SHORT,
    "short int"              => Fiddle::TYPE_SHORT,
    "unsigned short"         => -Fiddle::TYPE_SHORT,
    "short unsigned int"     => -Fiddle::TYPE_SHORT,
    "unsigned char"          => -Fiddle::TYPE_CHAR,
    "long long int"          => Fiddle::TYPE_LONG_LONG,
    "long long unsigned int" => -Fiddle::TYPE_LONG_LONG,
    "unsigned int"           => -Fiddle::TYPE_INT,
    "long unsigned int"      => -Fiddle::TYPE_LONG,
    "double"                 => Fiddle::TYPE_DOUBLE,
    "long int"               => Fiddle::TYPE_LONG,
    "_Bool"                  => Fiddle::TYPE_CHAR,
    "float"                  => Fiddle::TYPE_FLOAT,
    "void *"                 => Fiddle::TYPE_VOIDP,
  }.each_with_object({}) { |(k,v), h| h[k] = BasicType.new(k, v) }

  FIDDLE_TYPE_TO_NAME = Fiddle.constants.grep(/^TYPE_/).each_with_object({}) { |n, h|
    h[Fiddle.const_get(n)] = "Fiddle::#{n}"
  }

  class Emitter
    STRUCT_TEMPLATE = ERB.new(<<~eoerb, trim_mode: "-")
      # <%= struct.name %>
      <%- if struct.aliases.any? -%>
      # <%= struct.aliases.join(", ") %>
      <%- end -%>
      <%= "  " * indent %>Fiddle::CStructBuilder.create(Fiddle::<%= type_name %>,
      <%= "  " * indent %>[
      <%- struct.children.each do |child| -%>
      <%= "  " * indent %>  <%= emit_type(child.type, indent).chomp %>,
      <%- end -%>
      <%= "  " * indent %>],
      <%= "  " * indent %><%= PP.pp(struct.children.map(&:name), '') %>)<%= render_bitfields(struct, indent) %><%= render_autorefs(struct, indent) %>
    eoerb

    D4_BITFIELD_TEMPLATE = ERB.new(<<~eoerb, trim_mode: "-")
      .include(Module.new {
      <%- struct.bitfields.each do |bitfield| -%>
        <%- bitfield.children.each do |child| -%>
      <%= "  " * indent %>  def <%= child.name %>
      <%= "  " * indent %>    read_d4_bit(<%= child.die.data_member_location %>, <%= child.die.byte_size %>, <%= child.die.bit_offset %>, <%= child.die.bit_size %>)
      <%= "  " * indent %>  end
        <%- end -%>
      <%- end -%>
      <%= "  " * indent %>})
    eoerb

    D5_BITFIELD_TEMPLATE = ERB.new(<<~eoerb, trim_mode: "-")
      .include(Module.new {
      <%- struct.bitfields.each do |bitfield| -%>
        <%- bitfield.children.each do |child| -%>
      <%= "  " * indent %>  def <%= child.name %>; read_d5_bit(<%= child.die.data_bit_offset %>, <%= child.die.bit_size %>); end
        <%- end -%>
      <%- end -%>
      <%= "  " * indent %>})
    eoerb

    AUTOREF_TEMPLATE = ERB.new(<<~eoerb, trim_mode: "-")
      .prepend(Module.new {
      <%- struct.autorefs.each do |autoref| -%>
      <%= "  " * indent %>  def <%= autoref.name %>; STRUCTS[<%= autoref.ref_name.dump %>].new(super); end
      <%- end -%>
      <%= "  " * indent %>})
    eoerb

    def emit_symbols symbols, io: $stdout
      require "pp"
      io.puts "require \"fiddle\""
      io.puts "class TenderJIT"
      io.puts "  class Ruby"
      str = <<~eorb
      def self.adjust_addresses syms
        slide = Fiddle::Handle::DEFAULT["rb_st_insert"] - syms.fetch("rb_st_insert")
        syms.transform_values! { |v| v + slide }
        syms
      end
      eorb
      io.puts(indent(str, 4))
      io.print "    SYMBOLS = adjust_addresses("
      io.print PP.pp(symbols, '').chomp
      io.puts ")"
      io.puts "  end"
      io.puts "end"
    end

    def emit_constants enums, io: $stdout
      io.puts "class TenderJIT"
      io.puts "  class Ruby"

      constants = enums.inject({}) { |memo, enum| memo.merge enum.constants }

      len = constants.keys.max_by(&:length).length
      settable, not_settable = constants.partition { |name, _| name =~ /^[A-Z]/ }

      settable.each do |name, value|
        value &= 0xFFFFFFFF
        io.puts "    #{name.ljust(len)} = #{sprintf("%#x", value)}"
        if name =~ /^RUBY_(?:Q|T_)/
          io.puts "    #{name.delete_prefix("RUBY_").ljust(len)} = #{sprintf("%#x", value)}"
        end
      end

      io.puts "    OTHER_CONSTANTS = #{PP.pp(Hash[not_settable], '').chomp}"

      io.puts "  end"
      io.puts "end"
    end

    def emit_structs structs, io: $stdout
      io.puts "require \"fiddle\""
      io.puts "require \"fiddle/struct\""
      io.puts
      io.puts "class TenderJIT"
      io.puts "  class Ruby"
      io.puts "    STRUCTS = {}"

      seen = {}
      structs.each do |layout|
        layout.structs.each do |struct|
          next if struct.children.empty?
          name = struct.anonymous? ? struct.aliases.first : struct.name
          raise unless name
          next if seen.key? name
          seen[name] = true
          io.puts "    STRUCTS[#{name.dump}] ="
          io.puts indent(emit_struct(struct, 0), 6)
          struct.aliases.each do |aliaz|
            io.puts "    STRUCTS[#{aliaz.dump}] = STRUCTS[#{name.dump}]"
          end
        end
      end

      io.puts "  end"
      io.puts "end"
    end

    def indent str, w
      str.gsub(/^(?!$)/, " " * w)
    end

    def render_bitfields struct, indent
      return "" unless struct.has_bitfields?
      if struct.bitfields.map(&:d4?).any?
        D4_BITFIELD_TEMPLATE.result(binding)
      else
        D5_BITFIELD_TEMPLATE.result(binding)
      end
    end

    def render_autorefs struct, indent
      return "" unless struct.has_autorefs?
      AUTOREF_TEMPLATE.result(binding)
    end

    def emit_type type, indent
      case type
      when CStruct
        emit_struct type, indent + 1
      when CUnion
        emit_union type, indent + 1
      when BasicType
        name = FIDDLE_TYPE_TO_NAME[type.fiddle_type.abs]
        if type.fiddle_type.negative?
          "-#{name}"
        else
          name
        end
      when ArrayType
        "[ #{emit_type(type.type, indent)}, #{type.len} ]"
      else
        p type
        raise
      end
    end

    def emit_struct struct, indent
      emit_object struct, indent, "CStruct"
    end

    def emit_union struct, indent
      emit_object struct, indent, "CUnion"
    end

    def emit_object struct, indent, type_name
      STRUCT_TEMPLATE.result(binding).chomp
    end
  end

  class Enums
    attr_reader :constants

    def initialize constants
      @constants = constants
    end

    def enums?; true; end
    def structs?; false; end

    class << self
      def add cu, strs
        constants = {}
        cu.die.find_all { |x| x.tag.enumerator? }.each do |enum|
          name = enum.name(strs)#.delete_prefix("RUBY_")
          constants[name] = enum.const_value
        end
        new constants
      end
    end
  end

  class Structs
    attr_reader :structs

    def enums?; false; end
    def structs?; true; end

    def initialize structs
      @structs = structs
    end

    class << self
      def add unit, strs
        structs = []
        all_dies = unit.die.to_a
        unit.die.children.each do |child|
          next if child.tag.user?

          if child.tag.identifier == :DW_TAG_structure_type
            struct = build_struct(child, all_dies, strs)
            structs << struct
          end
        end
        new structs
      end

      def build_struct die, all_dies, strs
        build_object(die, all_dies, strs, type: CStruct)
      end

      def build_union die, all_dies, strs
        build_object(die, all_dies, strs, type: CUnion)
      end

      def build_member member_name, member_type, type_die, child, strs, all_dies
        case type_die.tag.identifier
        when :DW_TAG_structure_type
          SubStruct.new(member_name, child.data_member_location, member_type)
        when :DW_TAG_union_type
          SubUnion.new(member_name, child.data_member_location, member_type)
        when :DW_TAG_pointer_type
          pointer_type = find_type_die(type_die, all_dies)
          if pointer_type && (pointer_type.tag.structure_type? || pointer_type.tag.union_type?)
            ref_name = pointer_type.name(strs)
            AutoRefMember.new(member_name, ref_name, child.data_member_location, member_type)
          else
            Member.new(member_name, child.data_member_location, member_type)
          end
        when :DW_TAG_const_type, :DW_TAG_typedef, :DW_TAG_volatile_type
          build_member member_name, member_type, find_type_die(type_die, all_dies), child, strs, all_dies
        when :DW_TAG_base_type, :DW_TAG_array_type, :DW_TAG_enumeration_type
          Member.new(member_name, child.data_member_location, member_type)
        else
          raise type_die.tag.identifier.to_s
          exit!
          Member.new(member_name, child.data_member_location, member_type)
        end
      end

      def build_object die, all_dies, strs, type:
        name = die.name(strs) || "__anonymous"

        aliases = all_dies.find_all { |needle|
          needle.tag.identifier == :DW_TAG_typedef && needle.type == die.offset
        }.map { |x| x.name(strs) }

        children = die.children.find_all { |child| child.tag.member? }.map do |child|
          member_name = child.name(strs) || "__unknown_member"

          type_die = find_type_die(child, all_dies)

          member_type = resolve_type(type_die, all_dies, strs)

          if child.bit_offset # bitfields for DWARF 4
            D4BitMember.new(member_name, child.data_member_location, member_type, child)
          elsif child.data_bit_offset
            D5BitMember.new(member_name, child.data_member_location, member_type, child)
          else
            build_member member_name, member_type, type_die, child, strs, all_dies
          end
        end

        list = []

        while member = children.shift
          if member.bitfield?
            bitfields = [member]
            while children.first&.bitfield? && children.first.offset == member.offset
              bitfields << children.shift
            end
            list << BitMember.new(member.offset, member.type, bitfields)
          else
            list << member
          end
        end

        type.new(name, aliases, list)
      end

      def build_array die, all_dies, strs
        type = resolve_type find_type_die(die, all_dies), all_dies, strs
        ArrayType.new(type, die.count + 1)
      end

      def resolve_type type, all_dies, strs
        case type.tag.identifier
        when :DW_TAG_structure_type
          build_struct type, all_dies, strs
        when :DW_TAG_union_type
          build_union type, all_dies, strs
        when :DW_TAG_const_type, :DW_TAG_volatile_type, :DW_TAG_enumeration_type, :DW_TAG_typedef
          resolve_type find_type_die(type, all_dies), all_dies, strs
        when :DW_TAG_base_type
          name = type.name(strs)
          DWARF_TO_FIDDLE.fetch name
        when :DW_TAG_pointer_type
          DWARF_TO_FIDDLE.fetch "void *"
        when :DW_TAG_array_type
          build_array type, all_dies, strs
        else
          puts type.tag.identifier
          raise NotImplementedError, "Unknown type tag #{type.tag.identifier}"
        end
      end

      def find_type_die die, all_dies
        all_dies.bsearch { |c| die.type <=> c.offset }
      end
    end
  end
end

TenderJIT::RubyInternals.get_internals ARGV[0]
