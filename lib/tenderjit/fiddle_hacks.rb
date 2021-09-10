# Just some additions to fiddle that maybe we should upstream?

module Fiddle
  class CStruct
    INT_BITS = Fiddle::SIZEOF_INT * 8

    def read_d5_bit bit_offset, bit_size
      aligned_offset = ((bit_offset >> 5) << 5)
      buffer_loc = (aligned_offset / INT_BITS) * Fiddle::SIZEOF_INT

      bitfield = to_ptr[buffer_loc, Fiddle::SIZEOF_INT].unpack1("i!")
      bitfield >>= (bit_offset - aligned_offset)
      bitfield & ((1 << bit_size) - 1)
    end

    def read_d4_bit loc, byte_size, bit_offset, bit_size
      bits = byte_size * 8

      mask = 0xFFFFFFFF
      bitfield = to_ptr[loc, Fiddle::SIZEOF_INT].unpack1("i!")
      bitfield = mask & (bitfield << bit_offset)
      bitfield >> (bit_offset + (bits - (bit_size + bit_offset)))
    end
  end

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
