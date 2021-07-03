require "helper"

module TenderTools
  class RubyTest < TenderTools::Test
    def ruby_archive
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY"]
    end

    def test_ruby_archive
      assert File.file?(ruby_archive)
    end

    def test_read_archive
      files = []
      File.open(ruby_archive) do |f|
        AR.new(f).each { |file| files << file.identifier }
      end
      assert_includes files, "gc.o"
    end

    def test_read_archive_twice
      files = []
      File.open(ruby_archive) do |f|
        ar = AR.new(f)
        ar.each { |file| files << file.identifier }
        assert_includes files, "gc.o"
        files.clear
        ar.each { |file| files << file.identifier }
        assert_includes files, "gc.o"
      end
    end

    def test_macho_in_archive
      File.open(ruby_archive) do |f|
        ar = AR.new f
        gc = ar.find { |file| file.identifier == "gc.o" }

        f.seek gc.pos, IO::SEEK_SET
        macho = MachO.new f
        section = macho.find_section("__debug_str")
        assert_equal "__debug_str", section.sectname
      end
    end

    def test_macho_to_dwarf
      File.open(ruby_archive) do |f|
        ar = AR.new f
        gc = ar.find { |file| file.identifier == "gc.o" }

        f.seek gc.pos, IO::SEEK_SET
        macho = MachO.new f
        debug_strs = macho.find_section("__debug_str").as_dwarf
        debug_abbrev = macho.find_section("__debug_abbrev").as_dwarf
        debug_info = macho.find_section("__debug_info").as_dwarf

        names = []

        debug_info.compile_units(debug_abbrev.tags).each do |unit|
          unit.die.children.each do |die|
            names << die.name(debug_strs)
          end
        end

        assert_includes names, "RBasic"
      end
    end

    def test_rbasic_layout
      File.open(ruby_archive) do |f|
        ar = AR.new f
        gc = ar.find { |file| file.identifier == "gc.o" }

        f.seek gc.pos, IO::SEEK_SET
        macho = MachO.new f
        debug_strs = macho.find_section("__debug_str").as_dwarf
        debug_abbrev = macho.find_section("__debug_abbrev").as_dwarf
        debug_info = macho.find_section("__debug_info").as_dwarf

        rbasic_layout = []

        debug_info.compile_units(debug_abbrev.tags).each do |unit|
          unit.die.children.each do |die|
            if die.name(debug_strs) == "RBasic"
              assert_predicate die.tag, :structure_type?

              die.children.each do |child|
                field_name = child.name(debug_strs)
                field_type = nil
                while child
                  field_type = child.name(debug_strs)
                  break unless child.type
                  child = unit.die.find_type(child)
                end
                rbasic_layout << [field_name, field_type]
              end
            end
          end
        end

        assert_equal([["flags", "long unsigned int"], ["klass", "long unsigned int"]],
                     rbasic_layout)
      end
    end

    def test_rclass_layout
      File.open(ruby_archive) do |f|
        ar = AR.new f
        gc = ar.find { |file| file.identifier == "gc.o" }

        f.seek gc.pos, IO::SEEK_SET
        macho = MachO.new f
        debug_strs = macho.find_section("__debug_str").as_dwarf
        debug_abbrev = macho.find_section("__debug_abbrev").as_dwarf
        debug_info = macho.find_section("__debug_info").as_dwarf

        layout = []

        debug_info.compile_units(debug_abbrev.tags).each do |unit|
          unit.die.children.each do |die|
            if die.name(debug_strs) == "RClass"
              assert_predicate die.tag, :structure_type?

              die.children.each do |child|
                field_name = child.name(debug_strs)
                type = unit.die.find_type(child)

                if type.tag.typedef?
                  type = unit.die.find_type(type)
                end

                type_name = if type.tag.pointer_type?
                  c = unit.die.find_type(type)
                  "#{c.name(debug_strs)} *"
                else
                  type.name(debug_strs)
                end

                type_size = if type.tag.pointer_type?
                              unit.address_size
                            else
                              type.byte_size
                            end

                layout << [field_name, type_name, type_size]
              end
            end
          end
        end

        assert_equal([["basic", "RBasic", 16],
                      ["super", "long unsigned int", 8],
                      ["ptr", "rb_classext_struct *", 8],
                      ["class_serial", "long long unsigned int", 8]],
                     layout)
      end
    end

    [
      [:section?, MachO::Section],
      [:symtab?, MachO::LC_SYMTAB],
      [:segment?, MachO::LC_SEGMENT_64],
      [:dysymtab?, MachO::LC_DYSYMTAB],
      [:command?, MachO::Command],
    ].each do |predicate, klass|
      define_method :"test_find_#{predicate}" do
        File.open(RbConfig.ruby) do |f|
          my_macho = MachO.new f
          list = my_macho.find_all(&predicate)
          refute_predicate list, :empty?
          assert list.all? { |x| x.is_a?(klass) }
        end
      end
    end

    def test_rb_vm_get_insns_address_table
      sym = nil

      File.open(RbConfig.ruby) do |f|
        my_macho = MachO.new f

        my_macho.each do |section|
          if section.symtab?
            sym = section.nlist.find do |symbol|
              symbol.name == "_rb_vm_get_insns_address_table" && symbol.value
            end
            break if sym
          end
        end
      end

      addr = sym.value + Hacks.slide
      ptr = Fiddle::Function.new(addr, [], TYPE_VOIDP).call
      len = RubyVM::INSTRUCTION_NAMES.length
      p ptr[0, len * Fiddle::SIZEOF_VOIDP].unpack("Q#{len}")
    end

    def test_guess_slide
      File.open(RbConfig.ruby) do |f|
        my_macho = MachO.new f

        my_macho.each do |section|
          if section.symtab?
            section.nlist.each do |symbol|
              if symbol.name == "_rb_st_insert"
                guess_slide = Fiddle::Handle::DEFAULT["rb_st_insert"] - symbol.value
                assert_equal Hacks.slide, guess_slide
              end
            end
          end
        end
      end
    end

    def test_find_global
      File.open(RbConfig.ruby) do |f|
        my_macho = MachO.new f

        my_macho.each do |section|
          if section.symtab?
            section.nlist.each do |symbol|
              if symbol.name == "_ruby_api_version"
                if symbol.value > 0
                  addr = symbol.value + Hacks.slide
                  pointer = Fiddle::Pointer.new(addr, Fiddle::SIZEOF_INT * 3)
                  assert_equal RbConfig::CONFIG["ruby_version"].split(".").map(&:to_i),
                    pointer[0, Fiddle::SIZEOF_INT * 3].unpack("LLL")
                else
                  assert_predicate symbol, :stab?
                  assert_predicate symbol, :gsym?
                end
              end
            end
          end
        end
      end
    end
  end
end
