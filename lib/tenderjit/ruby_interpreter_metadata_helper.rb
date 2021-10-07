class TenderJIT
  class RubyInterpreterMetadataHelper
    # Returns a fingerprint of the current Ruby interpreter, based the Ruby description.
    #
    def self.fingerprint
      # The information is on the verbose side (in particular, CC_VERSION_MESSAGE,
      # which identifies the compiler version), but it's overall obvious and
      # comprehensive.
      #
      ruby_information = <<~eotxt
        #{RUBY_DESCRIPTION}
        #{RbConfig::CONFIG["CC"]}
        #{RbConfig::CONFIG["CC_VERSION_MESSAGE"]}
        #{RbConfig::CONFIG["CFLAGS"]}
      eotxt

      Digest::MD5.hexdigest(ruby_information)[0, 5]
    end
  end
end