# frozen_string_literal: true

require "helper"

class TenderJIT
  class SplatarrayTest < JITTest
    # Disassembly (for v3.0.2):
    #
    #   == disasm: #<ISeq:<compiled>@<compiled>:1 (1,0)-(1,13)> (catch: FALSE)
    #   local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
    #   [ 1] a@0
    #   0000 newarray                               0                         (   1)[Li]
    #   0002 setlocal_WC_0                          a@0
    #   0004 getlocal_WC_0                          a@0
    #   0006 splatarray                             true
    #   0008 leave
    #
    def splat_empty_array
      a = []
      [*a]
    end

    def test_splatarray
      compile(method(:splat_empty_array), recv: self)
      jit.enable!
      v = splat_empty_array
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [], v
    end

    def splat_param a
      [*a]
    end

    def test_splat_param_not_array
      compile(method(:splat_param), recv: self)
      jit.enable!
      v = splat_param 1
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [1], v
    end

    def test_splat_param_array
      compile(method(:splat_param), recv: self)
      jit.enable!
      v = splat_param [:a, :b]
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [:a, :b], v
    end

    def splat_bad_param a
      m = 5
      m + [*a].first
    end

    class Foo; def to_a; 1; end end

    def test_splat_exception
      compile(method(:splat_bad_param), recv: self)
      jit.enable!
      v = begin
            splat_bad_param Foo.new
          rescue TypeError
            :great
          end
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal :great, v
    end
  end
end
