# frozen_string_literal: true

require "tenderjit/util"
require "tenderjit/linked_list"

class TenderJIT
  class IR
    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out, :bb)
      include LinkedList::Element

      attr_writer :bb

      def phi?; false; end

      def registers
        [arg1, arg2, out].select(&:register?)
      end

      def lr1;    arg1.live_range; end
      def lr2;    arg2.live_range; end
      def lr_out; out.live_range; end

      def put_label?
        op == :put_label
      end

      def jump?
        !put_label? && out.label?
      end

      def replace arg1, arg2
        @arg1.remove_use self
        @arg2.remove_use self
        arg1.add_use self
        arg2.add_use self
        @arg1 = arg1
        @arg2 = arg2
        self
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

      def variables
        [out, arg1, arg2].select(&:variable?)
      end

      def set_variable
        if out.variable?
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
    end
  end
end
