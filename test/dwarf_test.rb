require "minitest/autorun"
require "mach-o"
require "dwarf"

module DWARF
  class Test < Minitest::Test
    debug_file = "fixtures/out.dSYM/Contents/Resources/DWARF/out"
    DEBUG_FILE = File.expand_path(File.join(__dir__, debug_file))

    def test_debug_abbrev
      io     = File.open DEBUG_FILE
      mach_o = MachO.new(io)

      section = mach_o.find do |thing|
        thing.section? && thing.sectname == "__debug_abbrev"
      end

      debug_abbrev = DWARF::DebugAbbrev.new io, section
      tags = debug_abbrev.tags

      assert_equal 5, tags.length
    end
  end
end
