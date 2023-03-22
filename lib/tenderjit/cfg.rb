# frozen_string_literal: true

class TenderJIT
  class CFG
    attr_reader :ir, :basic_blocks

    include Enumerable

    def initialize basic_blocks, ir
      @basic_blocks = clean(basic_blocks)
      @ir = ir
    end

    def clean blocks
      return blocks
      #blocks.each do |blk|
      #  blk.remove if blk.empty?
      #end

      #blocks
    end

    def each &blk
      @basic_blocks.each(&blk)
    end

    def reverse_each &blk
      @basic_blocks.reverse_each(&blk)
    end

    def each_instruction &blk
      @basic_blocks.each_instruction(&blk)
    end

    def assign_registers platform = Util::PLATFORM

      #File.binwrite("before_ra.dot", to_dot) if $DEBUG
      #printer = TenderJIT::BasicBlock::Printer.new(@basic_blocks)
      #$stderr.puts printer.to_dot

      spills = ra(platform).allocate(@basic_blocks, @ir)

      if spills > 0
        bytes = spills * Fiddle::SIZEOF_VOIDP
        bytes = (bytes + 15) & -16 # round up to the nearest 16
        @basic_blocks.first.start
        ir.insert_at(@basic_blocks.first.start) do |ir|
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

    def assemble platform = Util::PLATFORM
      assign_registers platform
      asm = self.code_generator platform
      @basic_blocks.dfs do |block|
        block.assemble asm
      end
      asm
    end
  end
end
