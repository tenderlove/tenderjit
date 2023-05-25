# frozen_string_literal: true

require "tenderjit/util"
require "tenderjit/linked_list"

class TenderJIT
  class IR
    class Instruction < Util::ClassGen.pos(:op, :arg1, :arg2, :out, :bb)
      include LinkedList::Element

      attr_writer :bb

      def phi?; false; end
      def call?; false; end

      def registers
        [arg1, arg2, out].select(&:register?)
      end

      def call cg, out, in1, in2
        cg.send op, out, in1, in2
      end

      def lr1;    arg1.live_range; end
      def lr2;    arg2.live_range; end
      def lr_out; out.live_range; end

      def inspect
        "#<#{self.class.name} #{op} #{out} #{arg1} #{arg2}>"
      end

      def put_label?
        op == :put_label
      end

      def jump?
        !put_label? && out.label?
      end

      def replace old, new
        arg1 = @arg1 == old ? new : @arg1
        arg2 = @arg2 == old ? new : @arg2

        @arg1.remove_use self
        @arg2.remove_use self
        arg1.add_use self
        arg2.add_use self
        @arg1 = arg1
        @arg2 = arg2
        self
      end

      def return?
        op == :ret
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

    class PatchLocation < Instruction
      attr_accessor :block

      def initialize op, arg1, arg2, out, bb = nil
        super
        @block = nil
      end

      def call cg, out, in1, in2
        cg.patch_location @block, in1, in2
      end
    end

    class Call < Instruction
      attr_reader :params

      def initialize op, arg1, arg2, out, bb = nil
        super(op, arg1, arg2, out, bb)
        @params = []
      end

      def add_param param
        param.add_use self
        @params << param
      end

      def call?; true; end

      def used_variables
        super + params
      end

      def replace old, new
        super
        if params.any? { |x| x == old }
          old.remove_use self
          new.add_use self
          @params = params.map { |param| param == old ? new : param }
        end
      end

      def call cg, out, in1, in2
        pushed = []
        (bb.live_out - [self.out]).each_slice(2) do |a, b|
          pushed << [a, b]
          cg.push(NONE, a, b || NONE)
        end

        x = cg.call out, in1, params

        pushed.reverse_each do |a, b|
          cg.pop(NONE, a, b || NONE)
        end

        x
      end
    end
  end
end
