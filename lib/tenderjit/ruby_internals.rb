require "rbconfig"
require "worf"
require "odinflex/mach-o"
require "odinflex/ar"
require "fiddle"
require "fiddle/struct"

class TenderJIT
  class RubyInternals
    class Internals
      include Fiddle

      attr_reader :archive, :encoded_instructions, :instruction_lengths

      class Fiddle::Function
        def to_proc
          this = self
          lambda { |*args| this.call(*args) }
        end
      end unless Function.method_defined?(:to_proc)

      def self.make_function name, args, ret
        ptr = Handle::DEFAULT[name]
        func = Function.new ptr, args, ret, name: name
        define_method name, &func.to_proc
      end

      make_function "rb_intern", [TYPE_CONST_STRING], TYPE_INT

      def initialize archive, slide, symbol_addresses, constants, structs, unions
        @archive              = archive
        @slide                = slide
        @symbol_addresses     = symbol_addresses
        @constants            = constants
        @structs              = structs
        @unions               = unions
        @encoded_instructions = read_encoded_instructions(symbol_addresses)
        @instruction_lengths  = read_instruction_lengths(symbol_addresses)
        @insn_to_name         = Hash[@encoded_instructions.zip(RubyVM::INSTRUCTION_NAMES)]
        @insn_len             = Hash[@encoded_instructions.zip(@instruction_lengths)]
      end

      def insn_name encoded_name
        @insn_to_name.fetch encoded_name
      end

      def insn_len encoded_name
        @insn_len.fetch encoded_name
      end

      def read_instruction_lengths symbol_addresses
        # FIXME: this needs to be tested on Linux, certainly the name will be
        # different.
        addr = symbol_addresses.fetch("insn_len.t")

        # FIXME: we should use DWARF data to figure out the array type rather
        # than hardcoding "sizeof char" below
        len  = RubyVM::INSTRUCTION_NAMES.length
        Fiddle::Pointer.new(addr)[0, len * SIZEOF_CHAR].unpack("C#{len}")
      end

      def read_encoded_instructions symbol_addresses
        addr = symbol_addresses["rb_vm_get_insns_address_table"]
        func = Fiddle::Function.new(addr, [], TYPE_VOIDP)
        buf  = func.call
        len  = RubyVM::INSTRUCTION_NAMES.length
        buf[0, len * SIZEOF_VOIDP].unpack("Q#{len}")
      end

      def symbol_address name
        @symbol_addresses[name]
      end

      def c name
        @constants[name]
      end

      def struct name
        @structs[name]
      end
    end

    def self.get_internals
      archive = nil
      symbol_addresses = {}
      constants = {}
      structs = {}
      unions = {}

      File.open(RbConfig.ruby) do |f|
        my_macho = OdinFlex::MachO.new f

        my_macho.each do |section|
          if section.symtab?
            section.nlist.each do |item|
              if item.archive?
                archive ||= item.archive
              else
                name = item.name.delete_prefix(RbConfig::CONFIG["SYMBOL_PREFIX"])
                symbol_addresses[name] = item.value if item.value > 0
              end
            end
          end
        end
      end

      # Fix up addresses due to ASLR
      slide = Fiddle::Handle::DEFAULT["rb_st_insert"] - symbol_addresses["rb_st_insert"]
      symbol_addresses.transform_values! { |v| v + slide }

      File.open(archive) do |f|
        ar = OdinFlex::AR.new f
        ar.each do |object_file|
          next unless object_file.identifier.end_with?(".o")
          next unless %w{ debug.o iseq.o gc.o st.o vm.o mjit.o }.include?(object_file.identifier)

          f.seek object_file.pos, IO::SEEK_SET
          macho = OdinFlex::MachO.new f

          debug_info = debug_strs = debug_abbrev = nil
          macho.each do |thing|
            if thing.section?
              case thing.sectname
              when "__debug_info"
                debug_info = thing.as_dwarf
              when "__debug_str"
                debug_strs = thing.as_dwarf
              when "__debug_abbrev"
                debug_abbrev = thing.as_dwarf
              else
              end
            end

            break if debug_info && debug_strs && debug_abbrev
          end

          raise "Couldn't find debug information" unless debug_info

          if object_file.identifier == "debug.o"
            debug_info.compile_units(debug_abbrev.tags).each do |unit|
              unit.die.find_all { |x| x.tag.enumerator? }.each do |enum|
                name = enum.name(debug_strs).delete_prefix("RUBY_")
                constants[name] = enum.const_value
              end
            end
          else
            builder = TypeBuilder.new(debug_info, debug_strs, debug_abbrev)
            builder.build
            structs.merge! builder.structs
            unions.merge! builder.unions
          end
        end
      end

      Internals.new(archive, slide, symbol_addresses, constants, structs, unions)
    end

    class TypeBuilder
      attr_reader :debug_info, :debug_strs, :debug_abbrev

      Type = Struct.new(:die, :fiddle)

      attr_reader :known_types, :structs, :unions

      def initialize debug_info, debug_strs, debug_abbrev
        @debug_info          = debug_info
        @debug_strs          = debug_strs
        @debug_abbrev        = debug_abbrev
        @known_types         = []
        @structs             = {}
        @unions              = {}
        @function_signatures = {}
      end

      def build
        debug_info.compile_units(debug_abbrev.tags).each do |unit|
          top = unit.die
          all_dies = top.to_a
          top.children.each do |die|
            next if die.tag.user?
            find_or_build die, all_dies
          end
        end
        @known_types.compact.each_with_object({}) do |type, hash|
          name = type.die.name(debug_strs)
          hash[name] = type.fiddle if name
        end
      end

      def handle_typedef die, all_dies
        name = die.name(@debug_strs)
        type = find_type_die(die, all_dies)
        if type.tag.identifier == :DW_TAG_structure_type
          @structs[name] = find_or_build type, all_dies
        end
      end

      def find_or_build die, all_dies
        object = @known_types[die.offset]
        return object.fiddle if object

        case die.tag.identifier
        when :DW_TAG_structure_type
          fiddle = build_fiddle(die, all_dies, Fiddle::CStruct)
          name = die.name(@debug_strs)
          @known_types[die.offset] = Type.new(die, fiddle)
          @structs[name] = fiddle if name
          fiddle
        when :DW_TAG_union_type
          fiddle = build_fiddle(die, all_dies, Fiddle::CUnion)
          name = die.name(@debug_strs)
          @known_types[die.offset] = Type.new(die, fiddle)
          @unions[name] = fiddle if name
          fiddle
        when :DW_TAG_array_type
          fiddle = build_array die, all_dies
          @known_types[die.offset] = Type.new(die, fiddle)
          fiddle
        #when :DW_TAG_subprogram
        #  name = die.name(@debug_strs)
        #  return_type = find_fiddle_type find_type_die(die, all_dies), all_dies
        #  param_types = die.children.map { |x|
        #    find_fiddle_type find_type_die(x, all_dies), all_dies
        #  }
        #  @function_signatures[name] = [param_types, return_type]
        when :DW_TAG_typedef
          handle_typedef die, all_dies
        end
      end

      def build_array die, all_dies
        type = find_fiddle_type find_type_die(die, all_dies), all_dies
        [type, die.count + 1]
      end

      DWARF_TO_FIDDLE = {
        "int"                    => Fiddle::TYPE_INT,
        "char"                   => Fiddle::TYPE_CHAR,
        "signed char"            => Fiddle::TYPE_CHAR,
        "short"                  => Fiddle::TYPE_SHORT,
        "unsigned short"         => -Fiddle::TYPE_SHORT,
        "unsigned char"          => -Fiddle::TYPE_CHAR,
        "long long int"          => Fiddle::TYPE_LONG_LONG,
        "long long unsigned int" => -Fiddle::TYPE_LONG_LONG,
        "unsigned int"           => -Fiddle::TYPE_INT,
        "long unsigned int"      => -Fiddle::TYPE_LONG,
        "double"                 => Fiddle::TYPE_DOUBLE,
        "long int"               => Fiddle::TYPE_LONG,
        "_Bool"                  => Fiddle::TYPE_CHAR,
        "float"                  => Fiddle::TYPE_FLOAT,
      }

      def find_type_die die, all_dies
        all_dies.bsearch { |c| die.type <=> c.offset }
      end

      def find_fiddle_type type_die, all_dies
        case type_die.tag.identifier
        when :DW_TAG_pointer_type
          Fiddle::TYPE_VOIDP
        when :DW_TAG_base_type
          name = type_die.name(debug_strs)
          DWARF_TO_FIDDLE.fetch name
        when :DW_TAG_const_type, :DW_TAG_volatile_type, :DW_TAG_enumeration_type, :DW_TAG_typedef
          if type_die.type
            sub_type = find_type_die(type_die, all_dies)
            find_fiddle_type sub_type, all_dies
          else
            raise
          end
        when :DW_TAG_structure_type
          find_or_build type_die, all_dies
        when :DW_TAG_array_type
          find_or_build type_die, all_dies
        when :DW_TAG_union_type
          find_or_build type_die, all_dies
        else
          raise "unknown member type #{type_die.tag.identifier}"
        end
      end

      def build_fiddle die, all_dies, fiddle_type
        return unless die.tag.has_children?

        types = []
        names = []
        last_offset = -1
        die.children.each do |child|
          case child.tag.identifier
          when :DW_TAG_member
            name = child.name(debug_strs)
            raise unless name

            type = find_type_die(child, all_dies)
            # deal with bitfield memebers
            if child.data_member_location == last_offset && fiddle_type == Fiddle::CStruct
              names.last << "|#{name}"
            else
              last_offset = child.data_member_location
              fiddle_subtype = find_fiddle_type(type, all_dies)
              if fiddle_subtype.is_a?(Class)
                names << [name, fiddle_subtype]
              else
                names << name
              end
              types << fiddle_subtype
            end
          when :DW_TAG_structure_type, :DW_TAG_union_type, :DW_TAG_enumeration_type
            # we can ignore sub structures. They should be built out
            # when the named member finds them
            # we can ignore sub structures. They should be built out
            # when the named member finds them
          else
            raise "unhandled type #{child.tag.identifier}"
          end
        end
        Fiddle::CStructBuilder.create(fiddle_type, types, names)
      end
    end
  end
end
