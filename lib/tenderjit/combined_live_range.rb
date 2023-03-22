# frozen_string_literal: true

class TenderJIT
  class CombinedLiveRange
    attr_reader :arg1, :arg2, :out

    def initialize arg1, arg2, out
      @arg1   = arg1
      @arg2   = arg2
      @out    = out
    end

    def definitions
      arg1.definitions + arg2.definitions + out.definitions
    end

    def combined?
      true
    end

    def name
      out.name
    end

    def spill ir, counter
      @arg1.spill(ir, counter)
      @arg2.spill(ir, counter) + @out.spill(ir, counter)
    end

    def physical_register= x
      @arg1.physical_register = x
      @arg2.physical_register = x
      @out.physical_register = x
    end

    def spill_cost
      @arg1.spill_cost + @arg2.spill_cost + @out.spill_cost
    end
  end
end
