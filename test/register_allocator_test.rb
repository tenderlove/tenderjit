require "helper"
require "tenderjit/ir"
require "tenderjit/register_allocator"
require "aarch64"

class TenderJIT
  class RegisterAllocatorTest < Test
    include TenderJIT::IR::Operands

    class TestRA < RegisterAllocator
      PARAM_REGS = 8.times.map { AArch64::Registers.const_get(:"X#{_1}") }.freeze

      FREE_REGS = [
        AArch64::Registers::X9,
        AArch64::Registers::X10,
      ].freeze

      def initialize
        super(PARAM_REGS, [:one, :two])
      end
    end

    def test_two_overlap_get_different_regs
      reg1 = VirtualRegister.new(1)
      reg2 = VirtualRegister.new(2)

      reg1.add_range 0, 15
      reg2.add_range 0, 15

      ra = TestRA.new
      pr1 = reg1.ensure ra, 0
      pr2 = reg2.ensure ra, 0

      assert_equal [:one, :two].sort, [pr1, pr2].map(&:unwrap).sort
    end

    def test_spills_raise
      reg1 = VirtualRegister.new(1)
      reg2 = VirtualRegister.new(2)
      reg3 = VirtualRegister.new(3)

      reg1.add_range 0, 15
      reg2.add_range 0, 15
      reg3.add_range 0, 15

      ra = TestRA.new
      pr1 = reg1.ensure ra, 0
      pr2 = reg2.ensure ra, 0

      assert_raises RegisterAllocator::Spill do
        reg3.ensure ra, 0
      end
    end

    def test_ensure_raises_outside_live_range
      reg1 = VirtualRegister.new(1)
      reg1.add_range 0, 15
      ra = TestRA.new

      assert_raises do
        reg1.ensure ra, 16
      end
    end

    def test_ensure_raises_in_lifetime_gap
      reg1 = VirtualRegister.new(1)
      reg1.add_range 17, 20
      reg1.add_range 0, 15

      ra = TestRA.new

      assert_raises do
        reg1.ensure ra, 16
      end
    end

    def test_freed_regs_get_reused
      reg1 = VirtualRegister.new(1)
      reg2 = VirtualRegister.new(2)
      reg3 = VirtualRegister.new(3)

      reg1.add_range 0, 15
      reg2.add_range 0, 0
      reg3.add_range 0, 15

      ra = TestRA.new
      pr1 = reg1.ensure ra, 0
      pr2 = reg2.ensure ra, 0

      reg2.free ra, 0

      pr3 = reg3.ensure ra, 0

      assert_equal [:one, :two].sort, [pr1, pr3].map(&:unwrap).sort
    end

    def test_reg_states
      reg = VirtualRegister.new(1)

      # Adding ranges happens backwardsly
      reg.add_range 5, 6
      reg.add_range 1, 1

      assert_equal :unhandled, reg.state_at(0)
      assert_equal :active, reg.state_at(1)
      assert_equal :inactive, reg.state_at(2)
      assert_equal :inactive, reg.state_at(3)
      assert_equal :inactive, reg.state_at(4)
      assert_equal :active, reg.state_at(5)
      assert_equal :active, reg.state_at(6)
      assert_equal :handled, reg.state_at(7)
    end

    def test_next_use
      reg = VirtualRegister.new(1)

      # Adding ranges happens backwardsly
      reg.add_range 15, 18
      reg.add_range 5, 6
      reg.add_range 1, 1

      assert_equal 1, reg.next_use(0)
      assert_equal 5, reg.next_use(2)
      assert_equal 5, reg.next_use(3)
      assert_equal 5, reg.next_use(4)
      assert_equal 15, reg.next_use(7)

      # It's already handled
      assert_raises ArgumentError do
        reg.next_use(18)
      end
    end

    def test_freeing_lends_register
      reg1 = VirtualRegister.new(1)
      reg2 = VirtualRegister.new(2)
      reg3 = VirtualRegister.new(3)

      reg1.add_range 0, 15

      # Adding ranges happens backwardsly
      reg2.add_range 5, 15
      reg2.add_range 0, 1

      reg3.add_range 2, 4  # fits in gap for reg2

      ra = TestRA.new

      [
        [reg1, reg2], # 0
        [reg1, reg2], # 1
        [reg1, reg3], # 2, reg3 should borrow reg2's physical register
        [reg1, reg3], # 3, reg3 should borrow reg2's physical register
        [reg1, reg3], # 4, reg3 should borrow reg2's physical register
        [reg1, reg2], # 5, reg2 should use its existing register
      ].each_with_index { |(l, r), i|
        pr1 = l.ensure ra, i
        pr2 = r.ensure ra, i
        if i >= 2 && i <= 4
          assert_equal pr2.unwrap, reg2.physical_register.unwrap
        end

        l.free ra, i
        r.free ra, i
      }
    end
  end
end
