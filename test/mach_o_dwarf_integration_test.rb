require "helper"

module TenderTools
  class MachODWARFIntegrationTest < Test
    def test_find_symbol_and_make_struct
      addr = nil
      archive = nil

      File.open(RbConfig.ruby) do |f|
        my_macho = MachO.new f
        my_macho.each do |section|
          if section.symtab?
            addr = section.nlist.find { |symbol|
              symbol.name == "_ruby_api_version" && symbol.value > 0
            }.value + Hacks.slide

            archive = section.nlist.find_all(&:archive?).map(&:archive).uniq.first
          end
        end
      end

      assert addr
      assert archive

      found_object = nil

      File.open(archive) do |f|
        ar = AR.new f
        ar.each do |object_file|
          next unless object_file.identifier.end_with?(".o")
          next unless object_file.identifier == "version.o"

          f.seek object_file.pos, IO::SEEK_SET
          macho = MachO.new f
          debug_info = macho.find_section("__debug_info")&.as_dwarf || next
          debug_strs = macho.find_section("__debug_str").as_dwarf
          debug_abbrev = macho.find_section("__debug_abbrev").as_dwarf

          debug_info.compile_units(debug_abbrev.tags).each do |unit|
            unit.die.children.each do |die|
              if die.name(debug_strs) == "ruby_api_version"
                found_object = object_file
              end
            end
          end
        end
      end

      assert found_object
    end
  end
end
