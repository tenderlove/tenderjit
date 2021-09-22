# frozen_string_literal: true

require "helper"

class TenderJIT
  class OptGetinlinecacheTest < JITTest
    def getconst
      OptGetinlinecacheTest
    end

    def test_opt_getinlinecache
      jit.compile(method(:getconst))

      # Keep calling "getconst" until it stops recompiling.  `opt_getinlinecache`
      # will try to keep recompiling until the global constant state settles
      stopped_recompiling = false
      10.times do
        recompiles = jit.recompiles
        jit.enable!
        getconst
        jit.disable!
        if recompiles == jit.recompiles
          stopped_recompiling = true
          break
        end
      end
      assert stopped_recompiling
      assert_change -> { jit.exits }, by: 0 do
        assert_change -> { jit.recompiles }, by: 0 do
          assert_change -> { jit.executed_methods } do
            jit.enable!
            v = getconst
            jit.disable!
            assert_equal OptGetinlinecacheTest, v
          end
        end
      end
    end
  end
end
