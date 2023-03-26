# frozen_string_literal: true

require "tenderjit/util"

class TenderJIT
  class BasicBlock
    class Head
      include Enumerable

      attr_accessor :out1
      attr_reader :dominators

      def initialize insn_head, ssa, ir
        @insn_head = insn_head
        @out1 = nil
        @ssa = ssa
        @ir = ir
        @dominators = [].freeze
      end

      def head; self; end

      def rebuild
        BasicBlock.build @insn_head, @ir, @ssa
      end

      def empty?; false; end

      def ssa?; @ssa; end

      def name; :HEAD; end

      def predecessors; []; end

      def dump_usage highlight_insn = nil
        @ir.dump_usage highlight_insn
      end

      def head?; true; end

      def falls_through?; true; end

      def jumps?; true; end

      def add_edge node
        raise ArgumentError if @out1
        @out1 = node
      end

      # Head block should only ever point at one thing
      def out2; end

      def each &blk
        @out1.each(&blk)
      end

      def reverse_each &blk
        @out1.reverse_each(&blk)
      end

      def dfs &blk
        @out1.dfs(&blk)
      end

      def each_instruction &blk
        return enum_for(:each_instruction) unless block_given?

        @out1.each do |bb|
          bb.each_instruction(&blk)
        end
      end

      def assemble platform = Util::PLATFORM
        if $DEBUG
          $stderr.print "#" * 10
          $stderr.print " BEFORE RA "
          $stderr.puts "#" * 10
          $stderr.puts BasicBlock::Printer.new(self).to_ascii
        end
        assign_registers platform
        if $DEBUG
          $stderr.print "#" * 10
          $stderr.print " AFTER RA "
          $stderr.puts "#" * 10
          $stderr.puts BasicBlock::Printer.new(self).to_ascii
        end
        asm = self.code_generator platform
        dfs do |block|
          block.assemble asm
        end
        asm
      end

      def assign_registers platform = Util::PLATFORM
        spills = ra(platform).allocate(self, @ir)

        if spills > 0
          bytes = spills * Fiddle::SIZEOF_VOIDP
          bytes = (bytes + 15) & -16 # round up to the nearest 16
          ir.insert_at(self.first.start) do |ir|
            ir.stack_alloc(bytes)
          end
          each_instruction do |insn|
            if insn.return?
              ir.insert_at(insn.prev) do |ir|
                ir.stack_delloc(bytes)
              end
            end
          end
        end
      end

      def ra platform
        if platform == :arm64
          require "tenderjit/arm64/register_allocator"
          ARM64::RegisterAllocator.new
        else
          require "tenderjit/x86_64/register_allocator"
          X86_64::RegisterAllocator.new
        end
      end

      def code_generator platform
        if platform == :arm64
          require "tenderjit/arm64/code_gen"
          ARM64::CodeGen.new
        else
          require "tenderjit/x86_64/code_gen"
          X86_64::CodeGen.new
        end
      end
    end
  end
end
