require "tenderjit/util"

class TenderJIT
  class IR
    class Variable < Util::ClassGen.pos(:name, :physical_register, :next_uses)
      attr_writer :physical_register

      def initialize name, physical_register = nil, next_uses = []
        super
      end

      def param?; false; end

      def used_after i
        next_uses.any? { |n| n > i }
      end
    end

    class InOut < Variable; end
    class Param < Variable
      def param?; true; end
    end
    class NamedVariable < Variable; end

    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out)
      attr_writer :reg, :n
    end

    attr_reader :instructions

    def initialize
      @instructions = []
    end

    def param idx; Param.new(idx); end

    def add arg1, arg2
      push __method__, arg1, arg2
    end

    def return arg1
      push __method__, arg1, arg1
    end

    private

    def push name, a, b
      out = InOut.new(@instructions.length)
      a.next_uses << @instructions.length
      b.next_uses << @instructions.length
      @instructions << Instruction.new(name, a, b, out)
      out
    end
  end
end
