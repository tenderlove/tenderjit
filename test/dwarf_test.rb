require "minitest/autorun"
require "mach-o"
require "dwarf"

module DWARF
  class Test < Minitest::Test
    debug_file = "fixtures/out.dSYM/Contents/Resources/DWARF/out"
    DEBUG_FILE = File.expand_path(File.join(__dir__, debug_file))

    def test_debug_abbrev
      File.open DEBUG_FILE do |io|
        mach_o = MachO.new(io)

        section = mach_o.find do |thing|
          thing.section? && thing.sectname == "__debug_abbrev"
        end

        debug_abbrev = DWARF::DebugAbbrev.new io, section
        tags = debug_abbrev.tags

        assert_equal 5, tags.length
      end
    end

    def test_debug_info
      File.open DEBUG_FILE do |io|
        mach_o = MachO.new(io)

        abbrev = mach_o.find do |thing|
          thing.section? && thing.sectname == "__debug_abbrev"
        end

        debug_abbrev = DWARF::DebugAbbrev.new io, abbrev

        section_info = mach_o.find do |thing|
          thing.section? && thing.sectname == "__debug_str"
        end

        strings = DWARF::DebugStrings.new io, section_info

        info = mach_o.find do |thing|
          thing.section? && thing.sectname == "__debug_info"
        end

        debug_info = DWARF::DebugInfo.new io, info, debug_abbrev
        units = debug_info.compile_units

        assert_equal 1, units.length
        assert_equal Constants::DW_TAG_compile_unit, units.first.tag.name
        assert_equal 5, units.first.children.length
        assert_equal Constants::DW_TAG_subprogram, units.first.children.first.tag.name
      end
    end
  end
end
