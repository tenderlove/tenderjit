# frozen_string_literal: true
class TenderJIT
  class CFG
    attr_reader :ir, :basic_blocks

    include Enumerable

    def initialize basic_blocks, ir
      @basic_blocks = clean(basic_blocks)
      @basic_blocks.live_ranges!
      @ir = ir
    end

    def dump_usage highlight_insn = nil
      @basic_blocks.dump_usage highlight_insn
    end

    def clean blocks
      return blocks
      blocks.each do |blk|
        blk.remove if blk.empty?
      end

      blocks
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
      result = ra(platform).allocate(@basic_blocks, @ir)
      spills = 0
      while result.spill?
        fix_spill result, @ir, spills
        spills += 1
        @basic_blocks.reset!
        result = ra(platform).allocate(@basic_blocks, @ir)
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

    def to_dot
      buf = "".dup
      buf << "digraph {\n"
      buf << "rankdir=TD; ordering=out;\n"
      buf << "node[shape=box fontname=\"Comic Code\"];\n"
      buf << "edge[fontname=\"Comic Code\"];\n"
      @basic_blocks.each do |block|
        buf << block.name.to_s
        buf << "[label=\"BB#{block.name}\\l"
        buf << "UE:       #{ir.vars block.ue_vars}\\l"
        buf << "Killed:   #{ir.vars block.killed_vars}\\l"
        buf << "Live Out: #{ir.vars block.live_out}\\l"
        if block.phis.any?
          block.phis.each do |phi|
            buf << "Phi: #{ir.vars [phi.out]} = "
            buf << "#{ir.vars phi.inputs}\\l"
          end
        end
        buf << "Dom:      #{block.dominators.map(&:name).join(",")}\\l"
        buf << ir.dump_insns(block.each_instruction.to_a, ansi: false)
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

    private

    def fix_spill e, ir, spills
      insn = e.insn
      active = e.active
      block = e.block
      iter          = insn
      spill_reg     = nil

      # Find spill candidate from the active registers
      while iter != block.finish
        break if active.empty?

        if active.include?(iter.arg1)
          spill_reg = iter.arg1
          active.delete iter.arg1
        end

        if active.include?(iter.arg2)
          spill_reg = iter.arg2
          active.delete iter.arg2
        end

        iter = iter._next
      end

      ir.insert_at(insn.prev) do |ir|
        ir.store(spill_reg, ir.sp, spills * 8)
      end

      iter = insn
      while iter != block.finish
        if iter.arg1 == spill_reg || iter.arg2 == spill_reg
          ir.insert_at(iter.prev) do |ir|
            var = ir.load(ir.sp, spills * 8)
            iter = iter.replace(iter.arg1 == spill_reg ? var : iter.arg1,
                                iter.arg2 == spill_reg ? var : iter.arg2)
          end
        end
        iter = iter._next
      end
    end
  end
end
