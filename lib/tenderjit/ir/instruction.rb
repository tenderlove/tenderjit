require "tenderjit/util"
require "tenderjit/linked_list"

class TenderJIT
  class IR
    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out, :number)
      include LinkedList::Element

      attr_writer :number

      def phi?; false; end

      def registers
        [arg1, arg2, out].select(&:register?)
      end

      def put_label?
        op == :put_label
      end

      def jump?
        !put_label? && out.label?
      end

      def replace arg1, arg2
        insn = self.class.new(op, arg1, arg2, out)
        append insn
        unlink
      end

      def return?
        op == :return
      end

      def unconditional_jump?
        op == :jmp
      end

      def has_jump_target?
        out.label?
      end

      def used_variables
        [arg1, arg2].select(&:variable?)
      end

      def set_variable
        if out.register?
          out
        end
      end

      def label
        raise unless put_label?
        out
      end

      def target_label
        return out if out.label?
        raise "not a jump instruction"
      end

      def clear_live_ranges!
        arg1.clear_live_ranges!
        arg2.clear_live_ranges!
        out.clear_live_ranges!
      end

      def used_at i
        arg1.set_last_use i
        arg2.set_last_use i
        out.set_first_use i
      end
    end
  end
end
