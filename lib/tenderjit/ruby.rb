# frozen_string_literal: true

require "digest/md5"

folder = Digest::MD5.hexdigest(RUBY_DESCRIPTION)[0, 5]

require "tenderjit/ruby/#{folder}/structs"
require "tenderjit/ruby/#{folder}/symbols"
require "tenderjit/ruby/#{folder}/constants"

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

    module GCC
      def self.read_instruction_lengths symbol_addresses
        # Instruction length tables seem to be compiled with numbers, and
        # embedded multiple times. Try to find the first one that has
        # the data we need
        symbol_addresses.keys.grep(/^t\.\d+/).each do |key|
          addr = symbol_addresses.fetch(key)
          len  = RubyVM::INSTRUCTION_NAMES.length
          list = Fiddle::Pointer.new(addr)[0, len * Fiddle::SIZEOF_CHAR].unpack("C#{len}")

          # This is probably it
          if list.first(4) == [1, 3, 3, 3]
            return list
          end
        end
      end

      def self.read_instruction_op_types symbol_addresses
        len  = RubyVM::INSTRUCTION_NAMES.length

        map = symbol_addresses.keys.grep(/^y\.\d+/).each do |key|
          insn_map = symbol_addresses.fetch(key)
          l = Fiddle::Pointer.new(insn_map)[0, len * Fiddle::SIZEOF_SHORT].unpack("S#{len}")
          break l if l.first(4) == [0, 1, 4, 7] # probably the right one
        end

        key = symbol_addresses.keys.grep(/^x\.\d+/).first
        op_types = symbol_addresses.fetch(key)

        str_buffer_end = map.last

        while Fiddle::Pointer.new(op_types + str_buffer_end)[0] != 0
          str_buffer_end += 1
        end
        Fiddle::Pointer.new(op_types)[0, str_buffer_end].unpack("Z*" * len)
      end
    end

    module Clang
      def self.read_instruction_op_types symbol_addresses
        # FIXME: this needs to be tested on Linux, certainly the name will be
        # different.
        op_types = symbol_addresses.fetch("insn_op_types.x")

        insn_map = symbol_addresses.fetch("insn_op_types.y")

        # FIXME: we should use DWARF data to figure out the array type rather
        # than hardcoding "sizeof short" below
        len  = RubyVM::INSTRUCTION_NAMES.length
        l = Fiddle::Pointer.new(insn_map)[0, len * Fiddle::SIZEOF_SHORT].unpack("S#{len}")
        str_buffer_end = l.last

        while Fiddle::Pointer.new(op_types + str_buffer_end)[0] != 0
          str_buffer_end += 1
        end
        Fiddle::Pointer.new(op_types)[0, str_buffer_end].unpack("Z*" * len)
      end

      def self.read_instruction_lengths symbol_addresses
        # FIXME: this needs to be tested on Linux, certainly the name will be
        # different.
        addr = symbol_addresses.fetch("insn_len.t")

        # FIXME: we should use DWARF data to figure out the array type rather
        # than hardcoding "sizeof char" below
        len  = RubyVM::INSTRUCTION_NAMES.length
        Fiddle::Pointer.new(addr)[0, len * Fiddle::SIZEOF_CHAR].unpack("C#{len}")
      end
    end

    class InsnInfo
      def self.boot
        decoder = case RbConfig::CONFIG["CC"]
                  when /^clang/ then Clang
                  when /^gcc/ then GCC
                  else
                    raise NotImplementedError, "Unknown compiler #{RbConfig::CONFIG["CC"]}"
                  end

        new decoder
      end

      def self.read_encoded_instructions symbol_addresses
        addr = symbol_addresses["rb_vm_get_insns_address_table"]
        func = Fiddle::Function.new(addr, [], Fiddle::TYPE_VOIDP)
        buf  = func.call
        len  = RubyVM::INSTRUCTION_NAMES.length
        buf[0, len * Fiddle::SIZEOF_VOIDP].unpack("Q#{len}")
      end

      def initialize decoder
        symbol_addresses = Ruby::SYMBOLS

        @encoded_instructions = self.class.read_encoded_instructions(symbol_addresses)
        @instruction_lengths  = decoder.read_instruction_lengths(symbol_addresses)
        @instruction_ops      = decoder.read_instruction_op_types(symbol_addresses)

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

    INSTANCE = Ruby.new InsnInfo.boot
  end
end
