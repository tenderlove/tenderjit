class MachO
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
    SIZEOF = 8 * 4 # 8 * (32 bit int)

    def section?; false; end
  end

  class Command
    attr_reader :cmd, :size
    def initialize cmd, size
      @cmd = cmd
      @size = size
    end

    def section?; false; end
  end

  class LC_UUID < Command
    VALUE = 0x1b
    SIZE  = 16 # uuid

    def self.from_io cmd, size, io
      new(cmd, size, io.read(SIZE))
    end

    attr_reader :uuid

    def initialize cmd, size, uuid
      super(cmd, size)
      @uuid = uuid
    end
  end

  class LC_BUILD_VERSION < Command
    VALUE = 0x32
    SIZE = 4 + # platform
           4 + # minos
           4 + # sdk
           4   # ntools

    def self.from_io cmd, size, io
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

    def self.from_io cmd, size, io
      new(cmd, size, *io.read(SIZE).unpack('L4'))
    end

    attr_reader :symoff, :nsyms, :stroff, :strsize

    def initialize cmd, size, symoff, nsyms, stroff, strsize
      super(cmd, size)
      @symoff  = symoff
      @nsyms   = nsyms
      @stroff  = stroff
      @strsize = strsize
    end
  end

  class LC_DYSYMTAB < Command
    VALUE = 0xb
    SIZE = 18 * 4

    def self.from_io cmd, size, io
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

    def self.from_io cmd, size, io
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
  end

  class Section < Struct.new :sectname, :segname, :addr, :size, :offset, :align, :reloff, :nreloc, :flags, :reserved1, :reserved2, :reserved3

    def section?; true; end
  end

  include Enumerable

  def each
    h = header
    yield h

    @fd.seek Header::SIZEOF, IO::SEEK_SET
    h.ncmds.times do
      cmd, size = @fd.read(2 * 4).unpack('LL')
      case cmd
      when LC_SEGMENT_64::VALUE
        lc = LC_SEGMENT_64.from_io(cmd, size, @fd)
        yield lc
        lc.nsects.times do
          args = @fd.read(32 + (2 * 8) + (8 * 4)).unpack('A16A16QQL8')
          save_pos do
            yield Section.new(*args)
          end
        end
      when LC_BUILD_VERSION::VALUE
        yield LC_BUILD_VERSION.from_io(cmd, size, @fd)
      when LC_SYMTAB::VALUE
        yield LC_SYMTAB.from_io(cmd, size, @fd)
      when LC_DYSYMTAB::VALUE
        yield LC_DYSYMTAB.from_io(cmd, size, @fd)
      when LC_UUID::VALUE
        yield LC_UUID.from_io(cmd, size, @fd)
      else
        p [sprintf("0x%02x", cmd), size]
        raise
      end
    end
  end

  def read section
    pos = @fd.pos
    @fd.seek section.offset, IO::SEEK_SET
    data = @fd.read(section.size)
    data.bytes.each_slice(16) do |list|
      p list.map { |x| sprintf("%02x", x) }.join ' '
    end
  ensure
    @fd.seek pos, IO::SEEK_SET
  end

  private

  def save_pos
    pos = @fd.pos
    yield
  ensure
    @fd.seek pos, IO::SEEK_SET
  end

  def header
    @fd.seek @start_pos, IO::SEEK_SET
    header = Header.new(*@fd.read(Header::SIZEOF).unpack('L8'))
    # I don't want to deal with endianness
    raise 'not supported' unless header.magic == 0xfeedfacf
    header
  end
end
