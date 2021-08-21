class TenderJIT
  class Runtime
    def initialize fisk, jit_buffer, temp_stack
      @fisk       = fisk
      @labels     = []
      @jit_buffer = jit_buffer
      @temp_stack = temp_stack

      yield self if block_given?
    end

    def rb_funcall recv, method_name, params
      raise "Too many parameters!" if params.length > 3

      func_addr = Internals.symbol_address "rb_funcall"

      @fisk.mov(Fisk::Registers::CALLER_SAVED[0], @fisk.uimm(Fiddle.dlwrap(recv)))
      @fisk.mov(Fisk::Registers::CALLER_SAVED[1], @fisk.uimm(CFuncs.rb_intern(method_name.to_s)))
      @fisk.mov(Fisk::Registers::CALLER_SAVED[2], @fisk.uimm(params.length))

      params.each_with_index do |param, i|
        i += 3

        if param.is_a?(Fisk::Operand)
          @fisk.mov(Fisk::Registers::CALLER_SAVED[i], param)

          if param.memory?
            @fisk.shl(Fisk::Registers::CALLER_SAVED[i], @fisk.uimm(1))
            @fisk.inc(Fisk::Registers::CALLER_SAVED[i])
          end
        else
          @fisk.mov(Fisk::Registers::CALLER_SAVED[i], @fisk.uimm(Fiddle.dlwrap(param)))
        end
      end

      @fisk.push(@fisk.rsp) # alignment
      @fisk.mov(@fisk.rax, @fisk.uimm(func_addr))
        .call(@fisk.rax)
      @fisk.pop(@fisk.rsp) # alignment
    end

    def jump location
      @fisk.jmp @fisk.absolute(location)
    end

    def flush
      write!
      @fisk = Fisk.new
    end

    def write!
      @fisk.assign_registers(TenderJIT::ISEQCompiler::SCRATCH_REGISTERS, local: true)
      @fisk.write_to(@jit_buffer)
      @fisk.freeze
    end

    def pointer reg, type: Fiddle::TYPE_VOIDP, offset: 0
      if reg.is_a? TemporaryVariable
        reg = reg.reg
      elsif reg.is_a?(Fisk::Operand) && reg.memory?
        offset = reg.displacement
        reg = reg.register
      end
      Pointer.new reg, type, find_size(type), offset, self
    end

    def sub reg, val
      @fisk.sub reg, @fisk.uimm(val)
    end

    def write_memory reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, val)
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def write_immediate reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.uimm(val))
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def read_to_reg src, offset
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.m64(src, offset))
        yield tmp
      end
    end

    def with_ref reg, offset
      @fisk.with_register do |tmp|
        @fisk.lea(tmp, @fisk.m(reg, offset))
        yield tmp
      end
    end

    def write_to_mem dst, offset, src
      @fisk.mov(@fisk.m64(dst, offset), src)
    end

    def write dst, src
      @fisk.mov(dst, src)
    end

    def break
      @fisk.int(@fisk.lit(3))
    end

    def test_flags obj, flags
      lhs = cast_to_fisk obj
      rhs = cast_to_fisk flags
      @fisk.test lhs, rhs
      @fisk.jz push_label  # else label
      finish_label = push_label
      yield
      @fisk.jmp finish_label # finish label
      self
    end

    def if lhs, op, rhs
      lhs = cast_to_fisk lhs
      rhs = cast_to_fisk rhs

      maybe_reg lhs do |op1|
        maybe_reg rhs do |op2|
          @fisk.cmp op1, op2
        end
      end
      @fisk.jg push_label # else label
      finish_label = push_label
      yield
      @fisk.jmp finish_label # finish label
      self
    end

    def if_eq lhs, rhs
      lhs = cast_to_fisk lhs
      rhs = cast_to_fisk rhs

      maybe_reg lhs do |op1|
        maybe_reg rhs do |op2|
          @fisk.cmp op1, op2
        end
      end
      @fisk.jne push_label # else label
      finish_label = push_label
      yield
      @fisk.jmp finish_label # finish label
      self
    end

    def else
      finish_label = pop_label
      else_label = pop_label
      @fisk.put_label else_label
      yield
      @fisk.put_label finish_label
    end

    # Dereference an operand in to a temp register and yield the register
    #
    # Basically just:
    #   `mov(tmp_reg, operand)`
    #
    def dereference operand
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, operand)
        yield tmp
      end
    end

    # Create a temporary variable
    def temp_var
      tv = TemporaryVariable.new @fisk.register, Fiddle::TYPE_VOIDP, Fiddle::SIZEOF_VOIDP, 0, self

      if block_given?
        yield tv
        tv.release!
      else
        tv
      end
    end

    # Push a value on the stack
    def push val, type:
      loc = @temp_stack.push type
      if val.is_a?(TemporaryVariable)
        write loc, val.reg
      else
        raise NotImplementedError
      end
    end

    def release_temp temp
      @fisk.release_register temp.reg
    end

    private

    def push_label
      label = "label #{@labels.length}"
      @labels.push label
      @fisk.label label
    end

    def pop_label
      @labels.pop
    end

    def maybe_reg op
      if op.immediate? && op.size == 64
        @fisk.with_register do |tmp|
          @fisk.mov(tmp, op)
          yield tmp
        end
      else
        yield op
      end
    end

    def cast_to_fisk val
      if val.is_a?(Fisk::Operand)
        val
      else
        @fisk.uimm(val)
      end
    end

    def find_size type
      type == Fiddle::TYPE_VOIDP ? Fiddle::SIZEOF_VOIDP : type.size
    end

    class Array
      attr_reader :reg, :type, :size

      def initialize reg, type, size, offset, event_coordinator
        @reg    = reg
        @type   = type
        @size   = size
        @offset = offset
        @ec     = event_coordinator
      end

      def [] idx
        Fisk::M64.new(@reg, @offset + (idx * size))
      end
    end

    class Pointer
      attr_reader :reg, :type, :size

      def initialize reg, type, size, base, event_coordinator
        @reg    = reg
        @type   = type
        @size   = size
        @base   = base
        @ec     = event_coordinator
      end

      # Yield a register that contains the address of this pointer
      def with_address offset = 0
        @ec.with_ref(@reg, @base + (offset * size)) do |reg|
          yield reg
        end
      end

      def [] idx
        Fisk::M64.new(@reg, @base + (idx * size))
      end

      def []= idx, val
        if val.is_a?(Fisk::Operand)
          if val.memory?
            @ec.write_memory @reg, idx * size, val
          else
            raise NotImplementedError
          end
        else
          @ec.write_immediate @reg, idx * size, val
        end
      end

      # Mutates this pointer.  Subtracts the size from itself.  Similar to
      # C's `--` operator
      def sub num = 1
        @ec.sub reg, size * num
      end

      def with_ref offset
        @ec.with_ref(@reg, @base + (offset * size)) do |reg|
          yield Pointer.new(reg, type, size, 0, @ec)
        end
      end

      def method_missing m, *values
        return super if type == Fiddle::TYPE_VOIDP

        member = m.to_s
        v      = values.first

        read = true

        if m =~ /^(.*)=/
          member = $1
          read = false
        end

        if read
          if idx = type.members.index { |n, _| n == member }
            sub_type = type.types[idx]
            if sub_type.respond_to?(:entity_class)
              return Pointer.new(@reg, sub_type, sub_type.size, @base + type.offsetof(member), @ec)
            end
          end
        end

        return super unless type.members.include?(member)

        if read
          if block_given?
            @ec.read_to_reg(@reg, type.offsetof(member)) do |reg|
              yield reg
            end
          else
            subtype = type.types[type.members.index(member)]
            if subtype.is_a?(::Array)
              Array.new(reg, subtype.first, Fiddle::PackInfo::SIZE_MAP[subtype.first], @base + type.offsetof(member), @ec)
            else
              return Fisk::M64.new(@reg, @base + type.offsetof(member))
            end
          end

        else
          if v.is_a?(Pointer)
            @ec.write_to_mem @reg, type.offsetof(member), v.reg
          else
            @ec.write_immediate @reg, type.offsetof(member), v.to_i
          end
        end
      end
    end

    class TemporaryVariable < Pointer
      # Write something to the temporary variable
      def write operand
        @ec.write reg, operand
      end

      # Release the temporary variable (say you are done using its value)
      def release!
        @ec.release_temp self
      end
    end
  end
end
