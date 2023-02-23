require "tenderjit/util"
require "tenderjit/linked_list"

class TenderJIT
  class IR
    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out, :number)
      include LinkedList::Element

      attr_writer :number

      def put_label?
        op == :put_label
      end

      def jump?
        !put_label? && (out.label? || op == :return)
      end

      def unconditional_jump?
        op == :return || op == :jmp
      end

      def has_jump_target?
        out.label?
      end

      def label
        raise unless put_label?
        out
      end

      def target_label
        return out if out.label?
        raise "not a jump instruction"
      end
    end
  end
end
