require "helper"
require "etc"
require "tenderjit/fiddle_hacks"

class TenderJIT
  class RubyInternalsTest < Test
    attr_reader :rb
    def setup
      super
      @rb = RubyInternals.get_internals
    end

    def test_RUBY_T_
      assert_equal 0,  rb.c("T_NONE")
      assert_equal 1,  rb.c("T_OBJECT")
      assert_equal 2,  rb.c("T_CLASS")
      assert_equal 3,  rb.c("T_MODULE")
      assert_equal 4,  rb.c("T_FLOAT")
      assert_equal 5,  rb.c("T_STRING")
      assert_equal 6,  rb.c("T_REGEXP")
      assert_equal 7,  rb.c("T_ARRAY")
      assert_equal 8,  rb.c("T_HASH")
      assert_equal 9,  rb.c("T_STRUCT")
      assert_equal 10, rb.c("T_BIGNUM")
      assert_equal 11, rb.c("T_FILE")
      assert_equal 12, rb.c("T_DATA")
      assert_equal 13, rb.c("T_MATCH")
      assert_equal 14, rb.c("T_COMPLEX")
      assert_equal 15, rb.c("T_RATIONAL")
      assert_equal 17, rb.c("T_NIL")
      assert_equal 18, rb.c("T_TRUE")
      assert_equal 19, rb.c("T_FALSE")
      assert_equal 20, rb.c("T_SYMBOL")
      assert_equal 21, rb.c("T_FIXNUM")
      assert_equal 22, rb.c("T_UNDEF")
      assert_equal 26, rb.c("T_IMEMO")
      assert_equal 27, rb.c("T_NODE")
      assert_equal 28, rb.c("T_ICLASS")
      assert_equal 29, rb.c("T_ZOMBIE")
      assert_equal 30, rb.c("T_MOVED")
      assert_equal 31, rb.c("T_MASK")
    end

    def test_get_internals
      assert_equal Fiddle::Handle::DEFAULT["rb_st_insert"], rb.symbol_address("rb_st_insert")
    end

    def test_get_internals_constants
      assert_equal 0, rb.c("Qfalse")
      assert_equal 30, rb.c("T_MOVED")
    end

    def test_typedef_equal_non_typedef
      assert_same rb.struct("rb_iseq_t"), rb.struct("rb_iseq_struct")
    end

    def test_encoded_instructions
      rTypedData            = rb.struct("RTypedData")
      rb_iseq_t             = rb.struct("rb_iseq_t")
      rb_iseq_constant_body = rb.struct("rb_iseq_constant_body")
      rb_iseq = RubyVM::InstructionSequence.of(method(__method__))
      iseq    = rb_iseq_t.new rTypedData.new(Fiddle.dlwrap(rb_iseq)).data
      body    = rb_iseq_constant_body.new iseq.body

      ary = Fiddle::CArray.unpack(body.iseq_encoded, body.iseq_size, Fiddle::TYPE_VOIDP)

      assert_equal "putself", rb.insn_name(ary[0])

      idx = 0
      rb_iseq.to_a.last.each do |insn|
        next unless insn.is_a?(Array)
        name = insn.first
        assert_equal name.to_s, rb.insn_name(ary[idx])
        assert_equal insn.length, rb.insn_len(ary[idx])
        idx += insn.length
      end
    end

    def test_RBasic2
      rBasic = rb.struct("RBasic")

      assert_rBasic rBasic

      # Test we can extract the class from an rBasic
      foo = Foo.new
      wrapper = rBasic.new(Fiddle.dlwrap(foo))
      assert_equal Foo, Fiddle.dlunwrap(wrapper.klass)
    end

    class Foo; end

    class ClassWithIvars
      def initialize
        @a = "hello"
        @b = "world"
        @c = "neat"
      end
    end

    def test_RBasic
      rBasic = rb.struct("RBasic")
      assert_rBasic rBasic

      # Test we can extract the class from an rBasic
      foo = Foo.new
      wrapper = rBasic.new(Fiddle.dlwrap(foo))
      assert_equal Foo, Fiddle.dlunwrap(wrapper.klass)
    end

    def test_RObject
      rObject = rb.struct("RObject")

      assert_equal ["basic", "as"], rObject.members.map(&:first)

      assert_rBasic rObject.types.first

      # RObject union
      rObject_as = rObject.types.last

      case rObject_as.members
      in [[heap, _], ary]
        assert_equal "heap", heap
        assert_equal "ary", ary
      else
        flunk
      end

      # Check the "heap" member. It's a struct
      rObject_as_heap = rObject_as.types.first
      assert_equal ["numiv", "ivptr", "iv_index_tbl"], rObject_as_heap.members
      assert_equal [-Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], rObject_as_heap.types

      # Check the "ary" member. It's an array of unsigned long
      assert_equal [-Fiddle::TYPE_LONG, 3], rObject_as.types.last
    end

    def CheckType(ptr, type)
      (ptr.flags | TYPE_MASK) == type
    end

    def test_read_RObject_ivars
      rObject = rb.struct("RObject")

      obj = ClassWithIvars.new
      ptr = rObject.new Fiddle.dlwrap obj

      assert_equal "hello", Fiddle.dlunwrap(ptr.as.ary[0])
      assert_equal "world", Fiddle.dlunwrap(ptr.as.ary[1])
      assert_equal "neat", Fiddle.dlunwrap(ptr.as.ary[2])
    end

    require "fisk"
    require "crabstone"

    def print_disasm binary
      cs = Crabstone::Disassembler.new(Crabstone::ARCH_X86, Crabstone::MODE_64)
      cs.disasm(binary, 0x0000).each {|i|
        printf("0x%x:\t%s\t\t%s\n",i.address, i.mnemonic, i.op_str)
      }
    end

    def test_constant_body_size
      rb_iseq_constant_body = rb.struct("rb_iseq_constant_body")
      assert_equal 288, rb_iseq_constant_body.size
    end

    def omg2; end

    def member_size type, member
      fiddle_type = type.types[type.members.index(member)]
      Fiddle::PackInfo::SIZE_MAP[fiddle_type]
    end

    def has_locals bar
      foo = 1
      foo += 1
      foo + bar
    end

    # We don't need to cast every pointer to its type, the structs know how
    # to do it for us.
    def test_automatic_casting
      rTypedData            = rb.struct("RTypedData")
      rb_iseq_t             = rb.struct("rb_iseq_struct")

      rb_iseq = RubyVM::InstructionSequence.of(method(:has_locals))
      iseq    = rb_iseq_t.new rTypedData.new(Fiddle.dlwrap(rb_iseq)).data

      assert_equal 2, iseq.body.local_table_size
    end

    def test_write_jit_body
      rTypedData            = rb.struct("RTypedData")
      rb_iseq_t             = rb.struct("rb_iseq_struct")
      rb_iseq_constant_body = rb.struct("rb_iseq_constant_body")
      rb_execution_context_t = rb.struct("rb_execution_context_struct")
      rb_control_frame_struct = rb.struct("rb_control_frame_struct")
      assert_equal 56, rb_control_frame_struct.size

      # Get the iseq pointer by extracting it from the Ruby object
      rb_iseq = RubyVM::InstructionSequence.of(method(:omg2))
      iseq    = rb_iseq_t.new rTypedData.new(Fiddle.dlwrap(rb_iseq)).data
      body    = rb_iseq_constant_body.new iseq.body
      assert_equal 0, body.jit_func.to_i

      fisk = Fisk.new

      jitbuf = Fisk::Helpers.jitbuffer 4096
      fmt = "%x\n"

      tc = self
      fisk.asm(jitbuf) do
        # ec is in rdi
        # cfp is in rsi
        push rbp
        mov rbp, rsp

        # Set up the registers like vm_exec wants:
        # PC is in r9 and CFP is in r8
        mov r8, rsi
        mov r9, m64(rsi, rb_control_frame_struct.offsetof("pc"))

        sizeof_sp = tc.member_size(rb_control_frame_struct, "sp")

        ### `putobject 1`
        # Increment the SP
        mov r10, m64(r8, rb_control_frame_struct.offsetof("sp"))
        add r10, imm32(sizeof_sp)
        mov m64(r8, sizeof_sp), r10

        # Write 1 to TOPN(0) of the stack
        mov m64(r10, -sizeof_sp), imm32(0x3)

        ### `leave` instruction
        # Copy top value from the stack in to rax
        #   `VALUE val = TOP(0);`
        mov r10, m64(r8, rb_control_frame_struct.offsetof("sp"))
        mov rax, m64(r10, -sizeof_sp)

        # Decrement SP
        #   `POPN(1)`
        sub r10, imm32(sizeof_sp)
        mov m64(r8, sizeof_sp), r10

        # Put EP in r11
        mov r11, m64(r8, rb_control_frame_struct.offsetof("ep"))
        mov r11, m64(r11) # EP flags

        # Previous CFP is in r10
        mov r10, r8
        add r10, imm32(rb_control_frame_struct.size)
        mov m64(rdi, rb_execution_context_t.offsetof("cfp")), r10

        pop rbp
        ret
      end

      body.jit_func = jitbuf.memory

      mjit_call_p = Fiddle::Pointer.new(rb.symbol_address("mjit_call_p"))
      mjit_opts = rb.struct("mjit_options").new(rb.symbol_address("mjit_opts"))
      mjit_opts.on = 1
      mjit_opts.min_calls = 5
      mjit_opts.wait = 0
      mjit_call_p[0] = 1
      assert_equal 1, omg2
      mjit_call_p[0] = 0
    end

    def omg; end

    def test_patch_mjit_to_call_tenderjit
      rTypedData            = rb.struct("RTypedData")
      rb_iseq_t             = rb.struct("rb_iseq_struct")

      # Get the iseq pointer by extracting it from the Ruby object
      iseq   = RubyVM::InstructionSequence.of(method(:omg))
      iseq_t = rb_iseq_t.new rTypedData.new(Fiddle.dlwrap(iseq)).data

      mjit_call_p = Fiddle::Pointer.new(rb.symbol_address("mjit_call_p"))
      mjit_opts = rb.struct("mjit_options").new(rb.symbol_address("mjit_opts"))

      addr = Fiddle::Handle::DEFAULT["rb_mjit_add_iseq_to_process"]

      func_memory = Fiddle::Pointer.new addr

      page_size = Etc.sysconf(Etc::SC_PAGE_SIZE)
      page_head = addr & ~(0xFFF)
      if CFuncs.mprotect(page_head, page_size, 0x1 | 0x4 | 0x2) != 0
        flunk
      end

      jit_iseq_addr = nil
      x = ->(iseq_addr) {
        # Disable MJIT
        mjit_call_p[0] = 0
        mjit_opts.on = 0

        jit_iseq_addr = iseq_addr
      }

      fisk = Fisk.new

      rb = self.rb
      binary = fisk.asm do
        push rbp
        mov rcx, rdi # save the first parameter, it's the iseq

        # encode the pointer as a Ruby integer
        shl rcx, imm8(0x1)
        self.or rcx, imm8(0x1)

        mov rdi, imm64(Fiddle.dlwrap(x))
        mov rsi, imm64(CFuncs.rb_intern("call"))
        mov rdx, imm32(1)
        mov r8, imm64(Fiddle::Handle::DEFAULT["rb_funcall"])
        call r8
        pop rbp
        ret
      end.string

      original_func_data = func_memory[0, binary.bytesize]
      func_memory[0, binary.bytesize] = binary

      # Enables MJIT
      mjit_opts.on = 1
      mjit_opts.min_calls = 5
      mjit_opts.wait = 0
      mjit_call_p[0] = 1

      omg
      omg
      omg
      omg
      omg
      omg

      # Put the assembly back
      func_memory[0, original_func_data.bytesize] = original_func_data
      assert_equal iseq_t.to_i, jit_iseq_addr
    end

    def assert_rBasic rBasic
      assert_equal [-Fiddle::TYPE_LONG, -Fiddle::TYPE_LONG], rBasic.types
      assert_equal ["flags", "klass"], rBasic.members
    end
  end
end
