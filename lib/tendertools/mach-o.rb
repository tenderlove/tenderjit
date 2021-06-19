module TenderTools
class MachO
  HEADER_MAGIC = 0xfeedfacf

  def self.is_macho? io
    pos = io.pos
    header = io.read(8).unpack1 'L'
    header == HEADER_MAGIC
  ensure
    io.seek pos, IO::SEEK_SET
  end

  attr_reader :start_pos

  def initialize fd
    @fd        = fd
    @start_pos = @fd.pos
  end

  class Header < Struct.new :magic,
                      :cputype,
                      :cpusubtype,
                      :filetype,
                      :ncmds,
                      :sizeofcmds,
                      :flags,
                      :reserved

    MH_OBJECT      = 0x1
    MH_EXECUTE     = 0x2
    MH_FVMLIB      = 0x3
    MH_CORE        = 0x4
    MH_PRELOAD     = 0x5
    MH_DYLIB       = 0x6
    MH_DYLINKER    = 0x7
    MH_BUNDLE      = 0x8
    MH_DYLIB_STUB  = 0x9
    MH_DSYM        = 0xa
    MH_KEXT_BUNDLE = 0xb
    MH_FILESET     = 0xc

    SIZEOF = 8 * 4 # 8 * (32 bit int)

    def section?; false; end
    def symtab?; false; end
    def segment?; false; end
    def dysymtab?; false; end
    def command?; false; end

    def object_file?
      filetype == MH_OBJECT
    end

    def executable_file?
      filetype == MH_EXECUTE
    end

    def dsym_file?
      filetype == MH_DSYM
    end
  end

  class Command
    attr_reader :cmd, :size

    def self.from_offset offset, io
      io.seek offset, IO::SEEK_SET
      cmd, size = io.read(2 * 4).unpack('LL')
      from_io cmd, size, offset, io
    end

    def initialize cmd, size
      @cmd = cmd
      @size = size
    end

    def section?; false; end
    def segment?; false; end
    def dysymtab?; false; end
    def symtab?; false; end
    def command?; true; end
  end

  class LC_UNIXTHREAD < Command
    VALUE = 0x04
    SIZE  = 16 # uuid

    def self.from_io cmd, size, offset, io
      new(cmd, size, io.read(SIZE))
    end

    attr_reader :uuid

    def initialize cmd, size, uuid
      super(cmd, size)
      @uuid = uuid
    end
  end

  class LC_FUNCTION_STARTS < Command
    VALUE = 0x26
    SIZE  = 4 + # dataoff
            4   # datasize

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE).unpack("LL"))
    end

    attr_reader :dataoff, :datasize

    def initialize cmd, size, dataoff, datasize
      super(cmd, size)
      @dataoff  = dataoff
      @datasize = datasize
    end
  end

  class LC_DATA_IN_CODE < LC_FUNCTION_STARTS
    VALUE = 0x29
  end

  class LC_LOAD_DYLIB < Command
    VALUE = 0xc

    def self.from_io cmd, size, offset, io
      # `size` is the total segment size including command and length bytes
      # so we need to remove them from the size.
      args = io.read(4 * 4).unpack('LLLL')
      io.seek offset + args.first, IO::SEEK_SET
      name = io.read(size - 8 - (4 * 4)).unpack1('A*')
      new(cmd, size, name, *args)
    end

    def initialize cmd, size, name, str_offset, timestamp, current_version, compat_version
      super(cmd, size)
      @name            = name
      @str_offset      = str_offset
      @timestamp       = timestamp
      @current_version = current_version
      @compat_version  = compat_version
    end
  end

  class LC_LOAD_DYLINKER < Command
    VALUE = 0xe

    def self.from_io cmd, size, offset, io
      # `size` is the total segment size including command and length bytes
      # so we need to remove them from the size.
      new(cmd, size, *io.read(size - 8).unpack('LA*'))
    end

    attr_reader :name

    def initialize cmd, size, offset, name
      super(cmd, size)
      @offset = offset
      @name = name
    end
  end

  class LC_VERSION_MIN_MACOSX < Command
    VALUE = 0x24
    SIZE  = 16 # uuid

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE))
    end

    attr_reader :uuid

    def initialize cmd, size, uuid
      super(cmd, size)
      @uuid = uuid
    end
  end

  class LC_UUID < Command
    VALUE = 0x1b
    SIZE  = 16 # uuid

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE))
    end

    attr_reader :uuid

    def initialize cmd, size, uuid
      super(cmd, size)
      @uuid = uuid
    end
  end

  class LC_SOURCE_VERSION < Command
    VALUE = 0x2A
    SIZE  = 8 # version

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE).unpack('Q'))
    end

    def initialize cmd, size, version
      super(cmd, size)
      @version = version
    end
  end

  class LC_BUILD_VERSION < Command
    VALUE = 0x32
    SIZE = 4 + # platform
           4 + # minos
           4 + # sdk
           4   # ntools

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE).unpack('L4'))
    end

    attr_reader :platform, :minos, :sdk, :ntools

    def initialize cmd, size, platform, minos, sdk, ntools
      super(cmd, size)
      @platform = platform
      @minos    = minos
      @sdk      = sdk
      @ntools   = ntools
    end
  end

  class LC_SYMTAB < Command
    VALUE = 0x2
    SIZE = 4 + # symoff
           4 + # nsyms
           4 + # stroff
           4   # strsize

    class NList < Struct.new(:name, :index, :type, :sect, :desc, :value)
      using Module.new {
        refine Integer do
          def inspect; sprintf("%#x", self); end
        end
      }

      # From stab.h
      N_GSYM  = 0x20 # global symbol
      N_FNAME = 0x22 # function name
      N_FUN   = 0x24 # function
      N_STSYM = 0x26
      N_LCSYM = 0x28
      N_BNSYM = 0x2e
      N_AST   = 0x32
      N_OPT   = 0x3c
      N_RSYM  = 0x40
      N_SLINE = 0x44
      N_ENSYM = 0x4e
      N_SSYM  = 0x60
      N_SO    = 0x64
      N_OSO   = 0x66

      constants.each { |n|
        define_method(n.to_s.sub(/^N_/, '').downcase + "?") { type == self.class::const_get(n) }
      }

      # define these constants after the above metaprogramming so they don't get
      # metaprogrammed methods :grimace:

      # From nlist.h
      N_STAB  = 0xe0
      N_PEXT  = 0x10
      N_TYPE  = 0x0e
      N_EXT   = 0x01

      def stab?; (type & N_STAB) != 0; end

      def archive?
        oso? && name =~ /[(][^)]*[)]$/
      end

      def archive
        name[/^.*(?=[(][^)]*[)]$)/]
      end

      def object
        name[/(?<=[(])[^)]*(?=[)]$)/]
      end

      def inspect
        start = "#<struct #{self.class} "
        members.inject(start) { |buffer, member|
          buffer + " #{member.to_s}=#{self[member].inspect}"
        } + ">"
      end
    end

    def self.from_io cmd, size, offset, io
      current = io.pos
      symoff, nsyms, stroff, strsize = *io.read(SIZE).unpack('L4')

      io.seek stroff, IO::SEEK_SET
      stable = io.read(strsize)

      io.seek symoff, IO::SEEK_SET

      nlist = nsyms.times.map do |i|
        index = io.read(4).unpack1 'L'
        x = stable.byteslice(index, stable.bytesize)
        unless x
          return new(cmd, size, symoff, nsyms, stroff, strsize, [])
        end
        name = x.unpack1 "Z*"
        NList.new(name, index, *io.read(1 + 1 + 2 + 8).unpack('CCsQ'))
      end
      new(cmd, size, symoff, nsyms, stroff, strsize, nlist)
    ensure
      io.seek current, IO::SEEK_SET
    end

    attr_reader :symoff, :nsyms, :stroff, :strsize, :nlist

    def initialize cmd, size, symoff, nsyms, stroff, strsize, nlist
      super(cmd, size)
      @symoff  = symoff
      @nsyms   = nsyms
      @stroff  = stroff
      @strsize = strsize
      @nlist   = nlist
    end

    def symtab?; true; end
  end

  class LC_DYSYMTAB < Command
    VALUE = 0xb
    SIZE = 18 * 4

    def dysymtab?; true; end

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE).unpack('L18'))
    end

    attr_reader :ilocalsym,
      :nlocalsym,
      :iextdefsym,
      :nextdefsym,
      :iundefsym,
      :nundefsym,
      :tocoff,
      :ntoc,
      :modtaboff,
      :nmodtab,
      :extrefsymoff,
      :nextrefsyms,
      :indirectsymoff,
      :nindirectsyms,
      :extreloff,
      :nextrel,
      :locreloff,
      :nlocrel

    def initialize cmd,
      size,
      ilocalsym,
      nlocalsym,
      iextdefsym,
      nextdefsym,
      iundefsym,
      nundefsym,
      tocoff,
      ntoc,
      modtaboff,
      nmodtab,
      extrefsymoff,
      nextrefsyms,
      indirectsymoff,
      nindirectsyms,
      extreloff,
      nextrel,
      locreloff,
      nlocrel
      super(cmd, size)

      @ilocalsym      = ilocalsym
      @nlocalsym      = nlocalsym
      @iextdefsym     = iextdefsym
      @nextdefsym     = nextdefsym
      @iundefsym      = iundefsym
      @nundefsym      = nundefsym
      @tocoff         = tocoff
      @ntoc           = ntoc
      @modtaboff      = modtaboff
      @nmodtab        = nmodtab
      @extrefsymoff   = extrefsymoff
      @nextrefsyms    = nextrefsyms
      @indirectsymoff = indirectsymoff
      @nindirectsyms  = nindirectsyms
      @extreloff      = extreloff
      @nextrel        = nextrel
      @locreloff      = locreloff
      @nlocrel        = nlocrel
    end
  end

  class LC_SEGMENT_64 < Command
    VALUE = 0x19
    SIZE = 16 + # segname
            8 + # vmaddr
            8 + # vmsize
            8 + # fileoff
            8 + # filesize
            4 + # maxprot
            4 + # initprot
            4 + # nsects
            4   # flags

    def self.from_io cmd, size, offset, io
      new(cmd, size, *io.read(SIZE).unpack('A16Q4L4'))
    end

    attr_reader :segname, :vmaddr, :vmsize, :fileoff, :filesize, :maxprot, :initprot, :nsects, :flags

    def initialize cmd, size, segname, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, flags
      super(cmd, size)
      @segname  = segname
      @vmaddr   = vmaddr
      @vmsize   = vmsize
      @fileoff  = fileoff
      @filesize = filesize
      @maxprot  = maxprot
      @initprot = initprot
      @nsects   = nsects
      @flags    = flags
    end

    def segment?; true; end
  end

  class Section < Struct.new :io, :start_pos, :sectname, :segname, :addr, :size, :offset, :align, :reloff, :nreloc, :flags, :reserved1, :reserved2, :reserved3

    def section?; true; end
    def symtab?; false; end
    def dysymtab?; false; end
    def segment?; false; end
    def command?; false; end

    def as_dwarf
      case sectname
      when "__debug_abbrev"
        DWARF::DebugAbbrev.new io, self, start_pos
      when "__debug_info"
        DWARF::DebugInfo.new io, self, start_pos
      when "__debug_str"
        DWARF::DebugStrings.new io, self, start_pos
      else
        raise NotImplementedError
      end
    end
  end

  include Enumerable

  def executable?
    header.executable_file?
  end

  def object?
    header.object_file?
  end

  def dsym?
    header.dsym_file?
  end

  def each
    h = header

    yield h

    @fd.seek @start_pos + Header::SIZEOF, IO::SEEK_SET

    next_pos = @fd.pos

    h.ncmds.times do |i|
      @fd.seek next_pos, IO::SEEK_SET

      cmd, size = @fd.read(2 * 4).unpack('LL')

      case cmd
      when LC_SEGMENT_64::VALUE
        lc = LC_SEGMENT_64.from_offset(next_pos, @fd)
        yield lc
        lc.nsects.times do
          args = @fd.read(32 + (2 * 8) + (8 * 4)).unpack('A16A16QQL8')
          yield Section.new(@fd, start_pos, *args)
        end
      when LC_FUNCTION_STARTS::VALUE
        yield LC_FUNCTION_STARTS.from_offset(next_pos, @fd)
      when LC_DATA_IN_CODE::VALUE
        yield LC_DATA_IN_CODE.from_offset(next_pos, @fd)
      when LC_BUILD_VERSION::VALUE
        yield LC_BUILD_VERSION.from_offset(next_pos, @fd)
      when LC_LOAD_DYLIB::VALUE
        yield LC_LOAD_DYLIB.from_offset(next_pos, @fd)
      when LC_LOAD_DYLINKER::VALUE
        yield LC_LOAD_DYLINKER.from_offset(next_pos, @fd)
      when LC_SOURCE_VERSION::VALUE
        yield LC_SOURCE_VERSION.from_offset(next_pos, @fd)
      when LC_SYMTAB::VALUE
        yield LC_SYMTAB.from_offset(next_pos, @fd)
      when LC_DYSYMTAB::VALUE
        yield LC_DYSYMTAB.from_offset(next_pos, @fd)
      when LC_UUID::VALUE
        yield LC_UUID.from_offset(next_pos, @fd)
      else
        # Just skip stuff we don't know about
        if $DEBUG
          puts "Unknown command #{cmd}"
        end
      end

      next_pos += size
    end
  end

  def find_section name
    find { |thing| thing.section? && thing.sectname == name }
  end

  def read section
    save_pos do
      @fd.seek @start_pos + section.offset, IO::SEEK_SET
      data = @fd.read(section.size)
      data.bytes.each_slice(16) do |list|
        p list.map { |x| sprintf("%02x", x) }.join ' '
      end
    end
  end

  def header
    @fd.seek @start_pos, IO::SEEK_SET
    header = Header.new(*@fd.read(Header::SIZEOF).unpack('L8'))
    # I don't want to deal with endianness
    raise 'not supported' unless header.magic == HEADER_MAGIC
    header
  end

  private

  def save_pos
    pos = @fd.pos
    yield
  ensure
    @fd.seek pos, IO::SEEK_SET
  end
end
end
