# Just some additions to fiddle that maybe we should upstream?

module Fiddle
  class CArray # :nodoc:
    def self.unpack ptr, len, type
      size = Fiddle::PackInfo::SIZE_MAP[type]
      bytesize = size * len
      ptr[0, bytesize].unpack("#{Fiddle::PackInfo::PACK_MAP[type]}#{len}")
    end
  end

  def self.read_ptr ptr, offset
    Fiddle::Pointer.new(ptr)[offset, Fiddle::SIZEOF_VOIDP].unpack1("l!")
  end

  def self.write_ptr ptr, offset, val
    data = [val].pack("l!")
    Fiddle::Pointer.new(ptr)[offset, Fiddle::SIZEOF_VOIDP] = data
    nil
  end

  def self.read_unsigned_int ptr, offset
    Fiddle::Pointer.new(ptr)[offset, Fiddle::SIZEOF_INT].unpack1(PackInfo::PACK_MAP[-TYPE_INT])
  end

  class CStruct
    def self.typeof item
      types[members.index(item)]
    end
  end
end
