require "helper"
require "tenderjit/ir"

class TenderJIT
  class OperandTest < Test
    include TenderJIT::IR::Operands

    def test_one_range
      reg = VirtualRegister.new(1, nil, [])
      reg.add_range 0, 15
      assert reg.used_at?(0)
      assert reg.used_at?(5)
      assert reg.used_at?(15)
      refute reg.used_at?(16)
    end

    def test_to_is_gt_or_eq_from
      reg = VirtualRegister.new(1, nil, [])
      assert_raises ArgumentError do
        reg.add_range 5, 0
      end
    end

    def test_add_range_must_be_backwards
      reg = VirtualRegister.new(1, nil, [])
      reg.add_range 0, 5
      assert_raises ArgumentError do
        reg.add_range 8, 15
      end
    end

    ##
    # The live range algorithm walks backwards through the instructions
    # adding a range that starts at the beginning of the block and ends at
    # the instruction number where we're recording.
    def test_multi_range_one_block
      reg = VirtualRegister.new(1, nil, [])
      reg.add_range 0, 15
      reg.add_range 0, 14
      reg.add_range 0, 13
      assert_equal 1, reg.ranges.length
      assert_equal 0, reg.ranges.first.first
      assert_equal 15, reg.ranges.first.last
    end

    ##
    # If a register is killed in a block, we add ranges at the use, but then
    # set the "from" to the kill point
    def test_killed
      reg = VirtualRegister.new(1, nil, [])
      reg.add_range 0, 15
      reg.add_range 0, 14
      reg.add_range 0, 13
      reg.set_from 5
      assert_equal 1, reg.ranges.length
      assert_equal 5, reg.ranges.first.first
      assert_equal 15, reg.ranges.first.last
    end

    def test_multi_block
      reg = VirtualRegister.new(1, nil, [])
      reg.add_range 5, 15
      reg.add_range 0, 4
      assert_equal 2, reg.ranges.length
      assert reg.used_at?(0)
      assert reg.used_at?(5)
      assert reg.used_at?(15)
      refute reg.used_at?(16)
    end

    def test_multi_block_with_hole
      reg = VirtualRegister.new(1, nil, [])
      reg.add_range 5, 15
      reg.add_range 0, 2
      assert_equal 2, reg.ranges.length
      assert reg.used_at?(0)
      assert reg.used_at?(5)
      assert reg.used_at?(15)
      refute reg.used_at?(3)
      refute reg.used_at?(4)
    end
  end
end
