class TenderJIT
  class RubyInterpreterMetadataHelper
    # Returns a fingerprint of the current Ruby interpreter, based the Ruby description.
    #
    def self.fingerprint
      Digest::MD5.hexdigest(RUBY_DESCRIPTION)[0, 5]
    end
  end
end