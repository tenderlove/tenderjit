require "tenderjit/util"

class TenderJIT
  class DSU
    class Node < Util::ClassGen.pos(:data, :parent)
      attr_writer :parent

      def initialize data, parent = self
        super
      end
    end
  end
end
