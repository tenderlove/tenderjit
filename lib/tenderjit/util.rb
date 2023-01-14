class TenderJIT
  module Util
    module ClassGen
      def self.pos *names
        Class.new do
          attr_reader *names
          sig = names.map { "#{_1} = nil" }.join(", ")
          init = names.map { "@#{_1} = #{_1}" }.join(";")
          class_eval("def initialize #{sig}; #{init}; end")
        end
      end
    end
  end
end
