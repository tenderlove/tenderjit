# frozen_string_literal: true

class TenderJIT
  class CombinedLiveRange
    attr_reader :arg1, :arg2, :out

    def initialize arg1, arg2, out
      @arg1 = arg1
      @arg2 = arg2
      @out = out
    end

    def rclass
      @out.rclass
    end

    def definitions
      arg1.definitions + arg2.definitions + out.definitions
    end

    def combined?
      true
    end

    def param?
      false
    end

    def hash
      name.hash
    end

    def eql? other
      name == other.name
    end

    def name
      out.name
    end

    def spill ir, counter
      # Spill inputs to the same place
      # then load outputs from the same place
      @arg1.live_range = @arg1
      @arg2.live_range = @arg2
      @out.live_range = @out
      @arg1.spill(ir, counter)
      @arg2.spill(ir, counter) + @out.spill(ir, counter)
      # puts "HI MOM"
      # exit!
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
