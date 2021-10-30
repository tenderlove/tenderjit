# frozen_string_literal: true

require "digest/md5"

require_relative "ruby_interpreter_metadata_helper"

folder = TenderJIT::RubyInterpreterMetadataHelper.fingerprint

require "tenderjit/fiddle_hacks"
require "tenderjit/ruby/#{folder}/structs"
require "tenderjit/ruby/#{folder}/symbols"
require "tenderjit/ruby/#{folder}/constants"
require "tenderjit/ruby/#{folder}/insn_info"

class TenderJIT
  class Ruby
    def self.read_encoded_instructions
      addr = Ruby::SYMBOLS["rb_vm_get_insns_address_table"]
      func = Fiddle::Function.new(addr, [], Fiddle::TYPE_VOIDP)
      buf  = func.call
      len  = RubyVM::INSTRUCTION_NAMES.length
      buf[0, len * Fiddle::SIZEOF_VOIDP].unpack("Q#{len}")
    end

    # From vm_core.h


    INTEGER_REDEFINED_OP_FLAG = (1 << 0)
    FLOAT_REDEFINED_OP_FLAG   = (1 << 1)
    STRING_REDEFINED_OP_FLAG  = (1 << 2)
    ARRAY_REDEFINED_OP_FLAG   = (1 << 3)
    HASH_REDEFINED_OP_FLAG    = (1 << 4)
    # /* #define BIGNUM_REDEFINED_OP_FLAG (1 << 5) */
    SYMBOL_REDEFINED_OP_FLAG  = (1 << 6)
    TIME_REDEFINED_OP_FLAG    = (1 << 7)
    REGEXP_REDEFINED_OP_FLAG  = (1 << 8)
    NIL_REDEFINED_OP_FLAG     = (1 << 9)
    TRUE_REDEFINED_OP_FLAG    = (1 << 10)
    FALSE_REDEFINED_OP_FLAG   = (1 << 11)
    PROC_REDEFINED_OP_FLAG    = (1 << 12)

    def initialize
      encoded_instructions = self.class.read_encoded_instructions

      @insn_to_name         = Hash[encoded_instructions.zip(RubyVM::INSTRUCTION_NAMES)]
      @insn_len             = Hash[encoded_instructions.zip(Ruby::INSN_LENGTHS)]
      @insn_to_ops          = Hash[encoded_instructions.zip(Ruby::INSN_OP_TYPES)]
    end

    def struct name
      Ruby::STRUCTS.fetch(name)
    end

    def symbol_address name
      Ruby::SYMBOLS.fetch(name)
    end

    def c name
      Ruby::OTHER_CONSTANTS.fetch(name) { Ruby.const_get name }
    end

    def constants
      Ruby.constants
    end

    def insn_name encoded_name
      @insn_to_name.fetch encoded_name
    end

    def insn_len encoded_name
      @insn_len.fetch encoded_name
    end

    def insn_op_types encoded_name
      @insn_to_ops.fetch encoded_name
    end

    def BASIC_OP_UNREDEFINED_P op, klass
      # (LIKELY((GET_VM()->redefined_flag[(op)]&(klass)) == 0))
      ruby_vm_redefined_flag[op] & klass == 0
    end

    def RB_IMMEDIATE_P obj_addr
      (obj_addr & RUBY_IMMEDIATE_MASK) != 0
    end

    def RB_TEST obj_addr
      (obj_addr & ~Qnil) != 0
    end

    def RB_SPECIAL_CONST_P obj_addr
      self.RB_IMMEDIATE_P(obj_addr) || !self.RB_TEST(obj_addr)
    end

    def rb_class_of obj_addr
      if !self.RB_SPECIAL_CONST_P(obj_addr)
        RBasic.klass(obj_addr).to_i
      else
        case obj_addr
        when Qfalse
          Fiddle.read_ptr Ruby::SYMBOLS["rb_cFalseClass"], 0
        when Qnil
          Fiddle.read_ptr Ruby::SYMBOLS["rb_cNilClass"], 0
        when Qtrue
          Fiddle.read_ptr Ruby::SYMBOLS["rb_cTrueClass"], 0
        else
          if self.RB_FIXNUM_P obj_addr
            Fiddle.read_ptr Ruby::SYMBOLS["rb_cInteger"], 0
          elsif self.RB_STATIC_SYM_P obj_addr
            Fiddle.read_ptr Ruby::SYMBOLS["rb_cSymbol"], 0
          elsif self.RB_FLONUM_P obj_addr
            Fiddle.read_ptr Ruby::SYMBOLS["rb_cFloat"], 0
          else
            raise "Unexpected type!"
          end
        end
      end
    end

    def VM_ENV_LOCAL_P ep
      flags = Fiddle.read_ptr(ep, VM_ENV_DATA_INDEX_FLAGS * Fiddle::SIZEOF_VOIDP)
      raise "Wrong flags" unless RB_FIXNUM_P(flags) # Check this is a fixnum
      flags & VM_ENV_FLAG_LOCAL == VM_ENV_FLAG_LOCAL
    end

    def VM_EP_LEP ep
      while !VM_ENV_LOCAL_P(ep)
        raise NotImplementedError
        # TODO: this isn't implemented / tested
        ep = VM_ENV_PREV_EP(ep)
      end
      ep
    end

    # https://github.com/ruby/ruby/blob/1038c4864f6f2e88d78e3dfd6b6fb94d7173aaa2/vm_core.h#L1263
    def VM_ENV_FLAGS ep, flag
      flags = Fiddle.read_ptr(ep, VM_ENV_DATA_INDEX_FLAGS * Fiddle::SIZEOF_VOIDP)
      flags & flag != 0
    end

    IMEMO_MASK = 0x0f # internal/imemo.h

    def imemo_type imemo
      (RBasic.flags(imemo) >> RUBY_FL_USHIFT) & IMEMO_MASK
    end

    # https://github.com/ruby/ruby/blob/844588f9157b364244a7d34ee0fcc70ccc2a7dd9/vm_insnhelper.c#L707
    def check_cref cref
      return if cref == Qfalse
      raise "cref should be IMEMO!" unless RB_BUILTIN_TYPE(cref) == T_IMEMO

      case imemo_type(cref)
      when c("imemo_ment")
        RbCallableMethodEntryT.new(cref).def.body.iseq.cref
      when c("imemo_cref")
        raise NotImplementedError
      when c("imemo_svar")
        raise NotImplementedError
      else
        raise "Unknown imemo type for cref"
      end
    end

    def vm_env_cref ep
      while !VM_ENV_LOCAL_P(ep)
        raise
      end
      check_cref Fiddle.read_ptr(ep, VM_ENV_DATA_INDEX_ME_CREF * Fiddle::SIZEOF_VOIDP)
    end

    def vm_get_ep ep, lv
      lv.times { ep = GET_PREV_EP(ep) }
      ep
    end

    def VM_ENV_BLOCK_HANDLER ep
      Fiddle.read_ptr(ep, VM_ENV_DATA_INDEX_SPECVAL * Fiddle::SIZEOF_VOIDP)
    end

    def vm_block_handler_type bh_ptr
      # https://github.com/ruby/ruby/blob/cbf2078a25c3efb12f45b643a636ff7bb4d402b6/vm_core.h#L1511-L1512

      # 0b...01 # ISeq block handler
      # 0b...11 # IFunc block handler
      if VM_BH_ISEQ_BLOCK_P(bh_ptr)
        c("block_handler_type_iseq")
      elsif VM_BH_IFUNC_P(bh_ptr)
        c("block_handler_type_ifunc")
      elsif RB_SYMBOL_P(bh_ptr)
        c("block_handler_type_symbol")
      else
        c("block_handler_type_proc")
      end
    end

    def VM_BH_IFUNC_P bh
      bh & 0x03 == 0x03
    end

    def VM_BH_ISEQ_BLOCK_P bh
      bh & 0x03 == 0x01
    end

    def VM_BH_TO_ISEQ_BLOCK bh
      bh & ~0x03
    end

    def RB_FIXNUM_P obj_addr
      0 != obj_addr & RUBY_FIXNUM_FLAG
    end
    alias :fixnum? :RB_FIXNUM_P

    def NIL_P obj_addr
      obj_addr == Qnil
    end

    def RB_SYMBOL_P obj_addr
      RB_STATIC_SYM_P(obj_addr) || RB_DYNAMIC_SYM_P(obj_addr)
    end

    UINTPTR_MAX = 0xFFFFFFFFFFFFFFFF # on macos anyway
    RBIMPL_VALUE_FULL = UINTPTR_MAX

    def RB_STATIC_SYM_P obj_addr
      mask = ~(RBIMPL_VALUE_FULL << RUBY_SPECIAL_SHIFT)
      (obj_addr & mask) == RUBY_SYMBOL_FLAG
    end

    def RB_DYNAMIC_SYM_P obj_addr
      return false if RB_SPECIAL_CONST_P(obj_addr)

      RB_BUILTIN_TYPE(obj_addr) == T_SYMBOL
    end

    def RB_FLONUM_P obj_addr
      (obj_addr & RUBY_FLONUM_MASK) == RUBY_FLONUM_FLAG
    end

    def RB_BUILTIN_TYPE obj_addr
      raise if RB_SPECIAL_CONST_P(obj_addr)

      RBasic.flags(obj_addr) & RUBY_T_MASK
    end

    def rb_current_vm
      Fiddle.read_ptr Ruby::SYMBOLS["ruby_current_vm_ptr"], 0
    end
    alias :GET_VM :rb_current_vm

    def ruby_vm_redefined_flag
      RbVmT.new(self.GET_VM).redefined_flag
    end

    INSTANCE = Ruby.new

    RbVmT = INSTANCE.struct "rb_vm_t"
  end
end
