# frozen_string_literal: true

require "digest/md5"

folder = Digest::MD5.hexdigest(RUBY_DESCRIPTION)[0, 5]

require "tenderjit/fiddle_hacks"
require "tenderjit/ruby/#{folder}/structs"
require "tenderjit/ruby/#{folder}/symbols"
require "tenderjit/ruby/#{folder}/constants"
require "tenderjit/ruby/#{folder}/insn_info"

class TenderJIT
  class Ruby
    def initialize insn_info
      @insn_info = insn_info
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

    def insn_name insn
      @insn_info.insn_name insn
    end

    def insn_len x
      @insn_info.insn_len x
    end

    def insn_op_types x
      @insn_info.insn_op_types x
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

    def RB_FIXNUM_P obj_addr
      0 != obj_addr & RUBY_FIXNUM_FLAG
    end

    def RB_BUILTIN_TYPE obj_addr
      raise if RB_SPECIAL_CONST_P(obj_addr)

      RBasic.flags(obj_addr) & RUBY_T_MASK
    end

    class InsnInfo
      def self.read_encoded_instructions symbol_addresses
        addr = symbol_addresses["rb_vm_get_insns_address_table"]
        func = Fiddle::Function.new(addr, [], Fiddle::TYPE_VOIDP)
        buf  = func.call
        len  = RubyVM::INSTRUCTION_NAMES.length
        buf[0, len * Fiddle::SIZEOF_VOIDP].unpack("Q#{len}")
      end

      def initialize
        symbol_addresses = Ruby::SYMBOLS

        @encoded_instructions = self.class.read_encoded_instructions(symbol_addresses)
        @instruction_lengths  = Ruby::INSN_LENGTHS
        @instruction_ops      = Ruby::INSN_OP_TYPES

        @insn_to_name         = Hash[@encoded_instructions.zip(RubyVM::INSTRUCTION_NAMES)]
        @insn_len             = Hash[@encoded_instructions.zip(@instruction_lengths)]
        @insn_to_ops          = Hash[@encoded_instructions.zip(@instruction_ops)]
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
    end

    INSTANCE = Ruby.new InsnInfo.new
  end
end
