require "fiddle"

class TenderJIT
  class CFuncs
    include Fiddle

    attr_reader :archive, :encoded_instructions, :instruction_lengths

    class Fiddle::Function
      def to_proc
        this = self
        lambda { |*args| this.call(*args) }
      end
    end unless Function.method_defined?(:to_proc)

    def self.make_function name, args, ret
      ptr = Handle::DEFAULT[name]
      func = Function.new ptr, args, ret, name: name
      define_singleton_method name, &func.to_proc
    end

    make_function "rb_intern", [TYPE_CONST_STRING], TYPE_INT
    make_function "rb_id2sym", [TYPE_INT], TYPE_VOIDP
    make_function "rb_id2str", [TYPE_INT], TYPE_VOIDP
    make_function "rb_sym2id", [TYPE_VOIDP], TYPE_INT
    make_function "memset", [TYPE_VOIDP, TYPE_INT, TYPE_SIZE_T], TYPE_VOID
    make_function "rb_st_lookup", [TYPE_VOIDP, TYPE_VOIDP, TYPE_VOIDP], TYPE_INT
    make_function "rb_ivar_set", [TYPE_VOIDP, TYPE_INT, TYPE_VOIDP], TYPE_VOIDP
    make_function "rb_callable_method_entry", [TYPE_VOIDP, TYPE_INT], TYPE_VOIDP
    make_function "rb_iseq_path", [TYPE_VOIDP], TYPE_VOIDP
    make_function "rb_iseq_label", [TYPE_VOIDP], TYPE_VOIDP
    make_function "rb_obj_class", [TYPE_VOIDP], TYPE_VOIDP
    make_function "rb_method_basic_definition_p", [TYPE_VOIDP, TYPE_INT], TYPE_INT
    make_function "rb_gc_writebarrier", [TYPE_VOIDP, TYPE_VOIDP], TYPE_VOID
  end
end
