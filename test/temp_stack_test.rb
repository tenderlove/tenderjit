# frozen_string_literal: true

require "helper"

class TempStackTest < TenderJIT::Test
  def test_push_symbol
    stack = TenderJIT::TempStack.new
    stack.push :foo, type: TenderJIT::T_SYMBOL
    assert_predicate stack.peek(0), :symbol?
  end

  def test_push_fixnum
    stack = TenderJIT::TempStack.new
    stack.push 123, type: TenderJIT::T_FIXNUM
    assert_predicate stack.peek(0), :fixnum?
  end

  def test_push_then_read_with_square
    stack = TenderJIT::TempStack.new
    stack.push("name")

    assert_equal 0, stack[0].displacement
  end

  def test_negative_numbers_raise_index_error_with_square
    stack = TenderJIT::TempStack.new
    assert_raises IndexError do
      stack[1]
    end

    assert_raises IndexError do
      stack[-1]
    end
  end

  def test_negative_index_raise_index_error_with_peek
    stack = TenderJIT::TempStack.new
    assert_raises IndexError do
      stack.peek(1)
    end

    assert_raises IndexError do
      stack.peek(-1)
    end
  end

  def test_push_then_read_with_peek
    stack = TenderJIT::TempStack.new
    stack.push("name")

    assert_equal "name", stack.peek(0).name
  end
end
