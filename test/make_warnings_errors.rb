# With $VERBOSE unset, warnings, and in turn errors, are not raised.
# Interestingly, as of v3.0.0, the documentation does not mention the case where
# $VERBOSE is false.
raise "In order to make errors into warnings, ensure that $VERBOSE is set!" unless $VERBOSE

# Make errors into warnings (gcc's -W)
# This is somewhat odd, but it's been officially accepted for this purpose (see https://bugs.ruby-lang.org/issues/3916).
module Warning
  undef :warn
  def warn msg
    raise msg
  end
end
