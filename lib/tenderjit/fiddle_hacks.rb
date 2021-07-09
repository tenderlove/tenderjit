# Just some additions to fiddle that maybe we should upstream?

module Fiddle
  class CArray # :nodoc:
    def self.unpack ptr, len, type
      size = Fiddle::PackInfo::SIZE_MAP[type]
      bytesize = size * len
      pack_format = Fiddle::PackInfo::PACK_MAP[type]
      ptr[0, bytesize].unpack("#{Fiddle::PackInfo::PACK_MAP[type]}#{len}")
    end
  end
end
