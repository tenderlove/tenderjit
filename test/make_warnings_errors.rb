# Make errors into warnings (gcc's -W)
# This is somewhat odd, but it's been officially accepted for this purpose (see https://bugs.ruby-lang.org/issues/3916).
#
module Warning
  def warn msg
    raise msg
  end
end
