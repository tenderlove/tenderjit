require "helper"
require "tenderjit/bitmatrix"

class BitMatrixTest < Minitest::Test
  def test_unset
    bm = TenderJIT::BitMatrix.new 32
    bm.set 0, 0
    assert bm.set?(0, 0)

    bm.unset 0, 0
    refute bm.set?(0, 0)
  end

  def test_bm
    bm = TenderJIT::BitMatrix.new 32
    bm.set 0, 0
    assert bm.set?(0, 0)
    refute bm.set?(0, 1)

    bm.set 5, 5
    assert bm.set?(5, 5)
    refute bm.set?(0, 1)
  end

  def test_extreme
    bm = TenderJIT::BitMatrix.new 32
    bm.set 31, 31
    assert bm.set?(31, 31)
  end

  def test_out_of_bounds
    bm = TenderJIT::BitMatrix.new 32

    assert_raises IndexError do
      bm.set 32, 0
    end

    assert_raises IndexError do
      bm.set 0, 32
    end
  end

  def test_65_bits
    bm = TenderJIT::BitMatrix.new 65
    bm.set 64, 0
    assert bm.set? 64, 0
    bm.set 0, 64
    assert bm.set? 0, 64
  end

  def test_lower_bits
    bm = TenderJIT::BitMatrix.new 32
    bm.set 5, 0
    assert bm.set? 5, 0
    assert bm.set? 0, 5

    bm.set 0, 6
    assert bm.set? 6, 0
    assert bm.set? 0, 6
  end

  def test_each_pair
    bm = TenderJIT::BitMatrix.new 32
    bm.set 5, 0
    bm.set 0, 6

    assert_equal [[0, 5], [0, 6]], bm.each_pair.to_a
  end

  def test_each_pair_larger
    bm = TenderJIT::BitMatrix.new 32
    bm.set 5, 0
    bm.set 0, 6
    bm.set 0, 15
    bm.set 12, 15
    bm.set 30, 31

    assert_equal [[0, 5], [0, 6], [0, 15], [12, 15], [30, 31]], bm.each_pair.to_a
  end

  def test_oob_set?
    bm = TenderJIT::BitMatrix.new 8
    assert_raises(IndexError) do
      bm.set?(5, 15)
    end

    assert_raises(IndexError) do
      bm.set?(15, 5)
    end
  end
end
