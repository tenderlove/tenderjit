# frozen_string_literal: true
class TenderJIT
  class CFG
    attr_reader :type

    include Enumerable

    def initialize basic_blocks, type
      @basic_blocks = clean(basic_blocks)
      @basic_blocks.live_ranges!
      @type = type
    end

    def dump_usage highlight_insn = nil
      @basic_blocks.dump_usage highlight_insn
    end

    def clean blocks
      blocks.each do |blk|
        blk.remove if blk.empty?
      end

      blocks
    end

    def each &blk
      @basic_blocks.each &blk
    end

    def reverse_each &blk
      @basic_blocks.reverse_each &blk
    end

    def each_instruction &blk
      @basic_blocks.each_instruction &blk
    end

    def assign_registers platform = Util::PLATFORM
      ra(platform).allocate @basic_blocks
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

    def to_binary platform = Util::PLATFORM
      assign_registers platform
      asm = self.code_generator platform
      each do |block|
        block.assemble asm
      end
      asm
    end

    def to_dot
      buf = "".dup
      buf << "digraph {\n"
      buf << "rankdir=TD; ordering=out;\n"
      buf << "node[shape=box fontname=\"Comic Code\"];\n"
      buf << "edge[fontname=\"Comic Code\"];\n"
      @basic_blocks.each do |block|
        buf << block.name.to_s
        buf << "[label=\"BB#{block.name}\\l"
        buf << "UE:       #{type.vars block.ue_vars}\\l"
        buf << "Killed:   #{type.vars block.killed_vars}\\l"
        buf << "Live Out: #{type.vars block.live_out}\\l"
        if block.phis.any?
          block.phis.each do |phi|
            buf << "Phi: #{type.vars [phi.out]} = "
            buf << "#{type.vars phi.vars}\\l"
          end
        end
        buf << "Dom:      #{block.dominators.map(&:name).join(",")}\\l"
        buf << type.dump_insns(block.each_instruction.to_a, ansi: false)
        buf << "\"];\n"
        if bb = block.out1
          buf << "#{block.name} -> #{bb.name} [label=\"out1\"];\n"
        end
        if bb = block.out2
          buf << "#{block.name} -> #{bb.name} [label=\"out2\"];\n"
        end
      end
      buf << "}\n"
      buf
    end
  end
end
