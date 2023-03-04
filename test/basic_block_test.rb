ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tenderjit/ir"
require "helper"

class TenderJIT
  class BasicBlockTest < Test
    def test_jump_start_has_own_bb
      ir = IR.new
      a = ir.param(0)
      b = ir.param(0)
      label = ir.label :finish
      ir.jle a, b, label
      ir.return a
      ir.put_label label
      ir.return a

      bb = ir.basic_blocks
      basic_blocks = bb.to_a
      assert_equal 3, basic_blocks.length

      bb = basic_blocks.first
      finish_ops = basic_blocks.map { |x| x.finish.op }
      assert_equal [:jle, :return, :return], finish_ops
    end

    def test_return_has_no_successors
      ir = IR.new
      a = ir.param(0)
      ir.return a

      basic_blocks = ir.basic_blocks.to_a
      assert_equal 1, basic_blocks.length

      bb = basic_blocks.first
      assert_equal :return, bb.finish.op

      finish = bb.finish
      refute_predicate bb, :has_jump_target? # no jump label for return
      refute_predicate bb, :labeled_entry? # no label on entry
      refute_predicate bb, :falls_through? # returns don't fall through
      assert_predicate finish, :return? # returns are returns
      assert_nil bb.out1
      assert_nil bb.out2
      assert_equal [], bb.successors
      assert_equal [], bb.predecessors.reject(&:head?)
    end

    def test_jmp_has_no_successors
      ir = IR.new
      label = ir.label :loop
      a = ir.param(0)
      b = ir.param(1)
      ir.put_label label
      c = ir.add(a, b)
      ir.jmp label

      bb = ir.basic_blocks
      assert_predicate bb, :head?
      basic_blocks = bb.to_a
      assert_equal 1, basic_blocks.length

      bb = basic_blocks.first
      assert_equal :jmp, bb.finish.op

      finish = bb.finish
      assert_predicate bb, :has_jump_target? # jumps to self
      assert_predicate bb, :labeled_entry? # label at head
      refute_predicate bb, :falls_through? # jmps don't fall through
      assert_predicate finish, :jump? # jmps are jumps
      assert_predicate finish, :unconditional_jump? # jmps are unconditional jumps
      assert_nil bb.out2
      assert_equal bb, bb.out1
      assert_equal [bb], bb.successors
      assert_equal 2, bb.predecessors.length # head and self
      assert_equal [bb], bb.predecessors.to_a.reject(&:head?)
    end

    def test_conditional_jump_falls_through
      ir = IR.new
      label = ir.label :loop
      a = ir.param(0)
      b = ir.param(1)
      ir.put_label label
      c = ir.add(a, b)
      ir.jne a, c, label
      ir.return 5

      basic_blocks = ir.basic_blocks.to_a
      assert_equal 2, basic_blocks.length

      bb = basic_blocks.first
      assert_equal :jne, bb.finish.op

      assert_equal 1, basic_blocks.last.to_a.length

      finish = bb.finish
      assert_predicate bb, :has_jump_target? # jumps to self
      assert_predicate bb, :labeled_entry? # label at head
      assert_predicate bb, :falls_through? # jne falls through
      assert_predicate finish, :jump? # jne are jumps
      refute_predicate finish, :unconditional_jump? # jne are conditional jumps
      assert_equal basic_blocks.last, bb.out1
      assert_equal bb, bb.out2
      assert_equal basic_blocks.sort_by(&:name), bb.successors.sort_by(&:name) # both blocks are successors
      assert_equal [bb], bb.predecessors.reject(&:head?) # jumps to itself

      # The return has the previous block as a predecessor
      assert_equal [bb], basic_blocks.last.predecessors
    end

    def test_tsort_cfg_reverse_jump
      ir = IR.new
      a = ir.param(0)
      b = ir.param(0)
      c = ir.add(a, b)

      last_block = ir.label(:last_block)
      # block 1 falls through to 2
      block_2 = ir.label(:block_2)
      ir.put_label block_2
      d = ir.add(a, c)
      ir.je(d, b, last_block)

      # mid block
      ir.nop
      ir.nop
      ir.jmp(block_2)

      # last_block
      ir.put_label(last_block)
      ir.return a

      blocks = ir.basic_blocks.to_a.sort_by(&:name)
      assert_equal 4, blocks.length

      cfg = ir.cfg
      assert_equal [0, 1, 2, 3], cfg.to_a.map(&:name)
    end

    def test_tsort_cfg_diamond
      ir = IR.new
      a = ir.param(0)
      b = ir.param(0)

      c = ir.add(a, b)

      finish = ir.label :finish
      left = ir.label :left
      ir.jne(a, b, left)  # if a != b
      ir.nop
      ir.jmp finish       #   jmp finish
      ir.put_label left   # else
      d = ir.add(c, a)    #   e = c + a
      ir.put_label finish
      ir.return d

      bbs = ir.basic_blocks.to_a.uniq.sort_by(&:name)
      assert_equal 4, bbs.length
      assert_equal [bbs[1], bbs[2]].sort_by(&:name), bbs.first.successors.sort_by(&:name)
      assert_equal [bbs.last], bbs[1].successors
      assert_equal [bbs.last], bbs[2].successors
      assert_equal [], bbs[3].successors

      cfg = ir.cfg
      assert_equal [0, 1, 2, 3], cfg.to_a.map(&:name)

      i = 0
      cfg.to_a.map(&:name).each do |idx|
        bb = bbs[idx]
        bb.each_instruction do |insn|
          assert_equal i, insn.number
          i += 1
        end
      end
    end
  end
end
