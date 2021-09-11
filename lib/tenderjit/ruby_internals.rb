# frozen_string_literal: true

require "rbconfig"
require "worf"
require "odinflex/mach-o"
require "odinflex/ar"
require "fiddle"
require "fiddle/struct"
require "tenderjit/fiddle_hacks"

class TenderJIT
  class RubyInternals
    def self.ruby_archive
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY_A"]
    end

    def self.ruby_so
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY_SO"]
    end

    def self.libruby
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY"]
    end

    module System
      module GCC
        def self.read_instruction_lengths symbol_addresses
          # Instruction length tables seem to be compiled with numbers, and
          # embedded multiple times. Try to find the first one that has
          # the data we need
          symbol_addresses.keys.grep(/^t\.\d+/).each do |key|
            addr = symbol_addresses.fetch(key)
            len  = RubyVM::INSTRUCTION_NAMES.length
            list = Fiddle::Pointer.new(addr)[0, len * Fiddle::SIZEOF_CHAR].unpack("C#{len}")

            # This is probably it
            if list.first(4) == [1, 3, 3, 3]
              return list
            end
          end
        end

        def self.read_instruction_op_types symbol_addresses
          len  = RubyVM::INSTRUCTION_NAMES.length

          map = symbol_addresses.keys.grep(/^y\.\d+/).each do |key|
            insn_map = symbol_addresses.fetch(key)
            l = Fiddle::Pointer.new(insn_map)[0, len * Fiddle::SIZEOF_SHORT].unpack("S#{len}")
            break l if l.first(4) == [0, 1, 4, 7] # probably the right one
          end

          key = symbol_addresses.keys.grep(/^x\.\d+/).first
          op_types = symbol_addresses.fetch(key)

          str_buffer_end = map.last

          while Fiddle::Pointer.new(op_types + str_buffer_end)[0] != 0
            str_buffer_end += 1
          end
          Fiddle::Pointer.new(op_types)[0, str_buffer_end].unpack("Z*" * len)
        end
      end

      module Clang
        def self.read_instruction_op_types symbol_addresses
          # FIXME: this needs to be tested on Linux, certainly the name will be
          # different.
          op_types = symbol_addresses.fetch("insn_op_types.x")

          insn_map = symbol_addresses.fetch("insn_op_types.y")

          # FIXME: we should use DWARF data to figure out the array type rather
          # than hardcoding "sizeof short" below
          len  = RubyVM::INSTRUCTION_NAMES.length
          l = Fiddle::Pointer.new(insn_map)[0, len * Fiddle::SIZEOF_SHORT].unpack("S#{len}")
          str_buffer_end = l.last

          while Fiddle::Pointer.new(op_types + str_buffer_end)[0] != 0
            str_buffer_end += 1
          end
          Fiddle::Pointer.new(op_types)[0, str_buffer_end].unpack("Z*" * len)
        end

        def self.read_instruction_lengths symbol_addresses
          # FIXME: this needs to be tested on Linux, certainly the name will be
          # different.
          addr = symbol_addresses.fetch("insn_len.t")

          # FIXME: we should use DWARF data to figure out the array type rather
          # than hardcoding "sizeof char" below
          len  = RubyVM::INSTRUCTION_NAMES.length
          Fiddle::Pointer.new(addr)[0, len * Fiddle::SIZEOF_CHAR].unpack("C#{len}")
        end
      end

      class Base
        def process folder
          layouts = []
          enums = []

          each_compile_unit do |cu, strings|
            enums << Layout::Enums.add(cu, strings)
            if cu.die.name(strings) != "debug.c"
              layouts << Layout::Structs.add(cu, strings)
            end
          end

          symbols = find_symbols

          decoder = case RbConfig::CONFIG["CC"]
                    when /^clang/ then Clang
                    when /^gcc/ then GCC
                    else
                      raise NotImplementedError, "Unknown compiler #{RbConfig::CONFIG["CC"]}"
                    end

          fixed_addresses = Fiddle.adjust_addresses symbols

          insn_lengths = decoder.read_instruction_lengths(fixed_addresses)
          insn_op_types = decoder.read_instruction_op_types(fixed_addresses)

          emitter = Layout::Emitter.new

          File.open("lib/tenderjit/ruby/#{folder}/symbols.rb", "w") { |f|
            f.puts "# frozen_string_literal: true"
            f.puts
            emitter.emit_symbols symbols, io: f
          }

          File.open("lib/tenderjit/ruby/#{folder}/constants.rb", "w") { |f|
            f.puts "# frozen_string_literal: true"
            f.puts
            emitter.emit_constants enums, io: f
          }

          File.open("lib/tenderjit/ruby/#{folder}/structs.rb", "w") { |f|
            f.puts "# frozen_string_literal: true"
            f.puts
            emitter.emit_structs layouts, io: f
          }

          File.open("lib/tenderjit/ruby/#{folder}/insn_info.rb", "w") { |f|
            f.puts "# frozen_string_literal: true"
            f.puts
            emitter.emit_insn_info insn_lengths, insn_op_types, io: f
          }
        end
      end

      module MachO
        class Base < System::Base
          private

          def each_compile_unit
            each_object_file do |f|
              # Get the DWARF info from each object file
              macho = OdinFlex::MachO.new f

              info = strs = abbr = nil

              macho.each do |thing|
                if thing.section?
                  case thing.sectname
                  when "__debug_info"
                    info = thing.as_dwarf
                  when "__debug_str"
                    strs = thing.as_dwarf
                  when "__debug_abbrev"
                    abbr = thing.as_dwarf
                  else
                  end
                end

                break if info && strs && abbr
              end

              if info && strs && abbr
                info.compile_units(abbr.tags).each do |unit|
                  yield unit, strs
                end
              end
            end
          end

          def find_symbols
            symbol_addresses = {}

            File.open symbol_file do |f|
              my_macho = OdinFlex::MachO.new f

              my_macho.each do |section|
                if section.symtab?
                  section.nlist.each do |item|
                    unless item.archive?
                      name = item.name.delete_prefix(RbConfig::CONFIG["SYMBOL_PREFIX"])
                      symbol_addresses[name] = item.value if item.value > 0
                    end
                  end
                end
              end
            end

            symbol_addresses
          end
        end

        class SharedObject < Base
          attr_reader :symbol_file

          def initialize libruby
            @symbol_file = libruby
          end

          private

          def each_object_file
            # Find all object files from the shared object
            object_files = File.open(symbol_file) do |f|
              my_macho = OdinFlex::MachO.new f
              my_macho.find_all(&:symtab?).flat_map do |section|
                section.nlist.find_all(&:oso?).map(&:name)
              end
            end

            object_files.grep(/(?:debug|iseq|gc|st|vm|mjit)\.[oc]$/).each do |f|
              File.open(f) { |fd| yield fd }
            end
          end
        end

        class Archive < Base
          attr_reader :symbol_file

          def initialize ruby_archive
            @ruby_archive = ruby_archive
            @symbol_file = RbConfig.ruby
          end

          private

          def each_object_file
            File.open @ruby_archive do |archive|
              ar = OdinFlex::AR.new archive
              ar.each do |object_file|
                next unless object_file.identifier =~ /(?:debug|iseq|gc|st|vm|mjit)\.[oc]$/

                yield archive
              end
            end
          end
        end
      end

      module ELF
        ELFAdapter = Struct.new(:offset, :size)

        class Base < System::Base
          private

          SHF_COMPRESSED = 1 << 11

          def read_section klass, file, section
            klass.new(file, ELFAdapter.new(section.header.sh_offset,
                                           section.header.sh_size), 0)
          end

          def read_compressed klass, file, section
            require "zlib"
            require "stringio"

            elf64_Chdr = [
              Fiddle::SIZEOF_INT, # Elf64_Word   ch_type;        /* Compression format.  */
              Fiddle::SIZEOF_INT, # Elf64_Word   ch_reserved;
              Fiddle::SIZEOF_LONG, # Elf64_Xword  ch_size;        /* Uncompressed data size.  */
              Fiddle::SIZEOF_LONG, # Elf64_Xword  ch_addralign;   /* Uncompressed data alignment.  */
            ]

            file.seek section.header.sh_offset, IO::SEEK_SET

            # Zlib info is _after_ the chdr header
            #type, _, size, align = file.read(elf64_Chdr.inject(:+)).unpack("IILL")
            _, _, size, _ = file.read(elf64_Chdr.inject(:+)).unpack("IILL")

            data = file.read section.header.sh_size

            data = Zlib.inflate(data)

            raise "Wrong data size" unless data.bytesize == size

            file = StringIO.new data

            klass.new(file, ELFAdapter.new(0, size), 0)
          end

          def read_dwarf section_name, klass, elf, file
            section  = elf.section_by_name(section_name)
            if section.header.sh_flags & SHF_COMPRESSED == SHF_COMPRESSED
              read_compressed klass, file, section
            else
              read_section klass, file, section
            end
          end

          def each_compile_unit
            File.open(@dwarf_file) do |f|
              elf = ELFTools::ELFFile.new f

              info = read_dwarf ".debug_info", WORF::DebugInfo, elf, f
              abbr = read_dwarf ".debug_abbrev", WORF::DebugAbbrev, elf, f
              strs = read_dwarf ".debug_str", WORF::DebugStrings, elf, f

              info.compile_units(abbr.tags).each do |unit|
                name = unit.die.name(strs)
                next unless name =~ /(?:debug|iseq|gc|st|vm|mjit)\.[oc]$/
                yield unit, strs
              end
            end
          end

          def find_symbols
            symbol_addresses = {}

            File.open(@symbol_file) do |f|
              elf = ELFTools::ELFFile.new f
              symtab_section = elf.section_by_name '.symtab'
              symtab_section.symbols.each do |item|
                name = item.name.delete_prefix(RbConfig::CONFIG["SYMBOL_PREFIX"])
                val = item.header.st_value
                symbol_addresses[name] = val
              end
            end

            symbol_addresses
          end
        end

        class SharedObject < Base
          def initialize ruby_so
            @symbol_file = ruby_so
            @dwarf_file = ruby_so
          end
        end

        class Archive < Base
          def initialize ruby_archive
            @symbol_file = RbConfig.ruby
            @dwarf_file = RbConfig.ruby
          end
        end
      end
    end

    def self.get_internals folder
      base_system = if RUBY_PLATFORM =~ /darwin/
                      System::MachO
                    else
                      require "elftools"
                      System::ELF
                    end

      # Ruby was built as a shared object.  We'll ask it for symbols
      info_strat = if libruby == ruby_so
                     base_system.const_get(:SharedObject).new(libruby)
                   else
                     base_system.const_get(:Archive).new(ruby_archive)
                   end

      info_strat.process folder
    end
  end
end
