class TenderJIT
  class Runtime
    def initialize fisk, jit_buffer, temp_stack
      @fisk       = fisk
      @labels     = []
      @label_count = 0
      @jit_buffer = jit_buffer
      @temp_stack = temp_stack
      @cfunc_call_stack_depth = 0 # Used for automatic alignment

      yield self if block_given?
    end

    def flush_pc_and_sp pc, sp
      cfp_ptr = pointer REG_CFP, type: RbControlFrameStruct
      cfp_ptr.pc = pc

      with_ref(sp) do |reg|
        cfp_ptr.sp = reg
      end
    end

    def load_address_in dest, src
      if src.memory?
        offset = src.displacement
        reg = src.register
      else
        raise NotImplementedError
      end

      @fisk.lea(dest, @fisk.m(reg, offset))
    end

    def check_vm_stack_overflow temp_stack, exit_location, local_size, stack_max
      margin = ((local_size + stack_max) * Fiddle::SIZEOF_VOIDP) + RbControlFrameStruct.byte_size

      loc = temp_stack.first.loc + (margin / Fiddle::SIZEOF_VOIDP)
      with_ref(loc) do |reg|
        self.if(reg, :>, REG_CFP) {
          # do nothing
        }.else {
          jump(exit_location)
        }
      end
    end

    # Converts the Ruby Number stored in +val+ to an int
    def NUM2INT val
      @fisk.sar(cast_to_fisk(val), @fisk.lit(1))
    end

    # Converts the Ruby Number stored in +val+ to an int
    def FIX2LONG val
      @fisk.sar(cast_to_fisk(val), @fisk.lit(1))
    end

    # Converts an int to a Ruby Number
    def INT2NUM val
      @fisk.shl(cast_to_fisk(val), @fisk.lit(1))
      @fisk.inc(cast_to_fisk(val))
    end

    def return_value
      @fisk.rax
    end

    def return_value= v
      @fisk.mov @fisk.rax, v
    end

    def patchable_jump dest
      @fisk.lea(return_value, @fisk.rip)
      jump dest
    end

    def patchable_call dest
      @fisk.call(@fisk.absolute(dest))
    end

    def call dest
      @fisk.call(dest)
    end

    # Get the register for the i'th parameter in the C calling convention
    def c_param i
      Fisk::Registers::CALLER_SAVED.fetch i
    end

    # Set the register for the i'th parameter in the C calling convention
    def set_c_param i, v
      @fisk.mov Fisk::Registers::CALLER_SAVED.fetch(i), v
    end

    def rb_funcall recv, method_name, params
      @fisk.push REG_BP.to_register # alignment
      rb_funcall_without_alignment recv, method_name, params
      @fisk.pop REG_BP.to_register  # alignment
    end

    def rb_funcall_without_alignment recv, method_name, params
      raise "Too many parameters!" if params.length > 3

      func_addr = Internals.symbol_address "rb_funcall"

      @fisk.mov(Fisk::Registers::CALLER_SAVED[0], @fisk.uimm(Fiddle.dlwrap(recv)))
      @fisk.mov(Fisk::Registers::CALLER_SAVED[1], @fisk.uimm(CFuncs.rb_intern(method_name.to_s)))
      @fisk.mov(Fisk::Registers::CALLER_SAVED[2], @fisk.uimm(params.length))

      params.each_with_index do |param, i|
        i += 3

        if param.is_a?(Fisk::Operand) || param.is_a?(TemporaryVariable)
          param = param.to_register if param.is_a?(TemporaryVariable)

          @fisk.mov(Fisk::Registers::CALLER_SAVED[i], param)

          #if param.memory?
            @fisk.shl(Fisk::Registers::CALLER_SAVED[i], @fisk.uimm(1))
            @fisk.inc(Fisk::Registers::CALLER_SAVED[i])
          #end
        else
          @fisk.mov(Fisk::Registers::CALLER_SAVED[i], @fisk.uimm(Fiddle.dlwrap(param)))
        end
      end

      @fisk.mov(@fisk.rax, @fisk.uimm(func_addr))
        .call(@fisk.rax)
    end

    def jump location
      case location
      when TemporaryVariable
        @fisk.jmp location.reg
      when Fisk::Operand
        @fisk.jmp location
      else
        @fisk.jmp @fisk.absolute(location)
      end
    end

    def and reg, num
      @fisk.and(reg, cast_to_fisk(num))
    end

    def or reg, num
      @fisk.or(reg, cast_to_fisk(num))
    end

    def xor reg, num
      @fisk.xor(reg, cast_to_fisk(num))
    end

    def flush
      write!
      @fisk = Fisk.new
    end

    # Writes to the buffer, and freezes the instance.
    # Returns the buffer, for convenience.
    #
    def write!
      @fisk.assign_registers(TenderJIT::ISEQCompiler::SCRATCH_REGISTERS, local: true)
      @fisk.write_to(@jit_buffer)
      @fisk.freeze
      @jit_buffer
    end

    def pointer reg, type: Fiddle::TYPE_VOIDP, offset: 0
      Pointer.new reg.to_register, type, find_size(type), offset, self
    end

    def sub reg, val
      @fisk.sub reg, cast_to_fisk(val)
    end

    def add reg, val
      @fisk.add reg.to_register, cast_to_fisk(val)
    end

    def inc reg
      @fisk.inc reg
    end

    def mult val1, val2
      raise NotImplementedError unless val1.memory?
      raise NotImplementedError unless val2.memory?

      # Put val in to RAX
      # mult should end up in r9, but is in rax
      @fisk.mov @fisk.rax, cast_to_fisk(val1)
      temp_var do |temp_1|
        @fisk.mov cast_to_fisk(temp_1), cast_to_fisk(val2)

        self.NUM2INT(temp_1)
        self.NUM2INT(@fisk.rax)

        # val1 should be in the rax register
        # and val2 should be in temp_1
        # Mulitply reg by the value in RAX
        @fisk.mul cast_to_fisk(temp_1)
      end

      self.INT2NUM(@fisk.rax)
      @fisk.rax
    end

    # Performs a 64-bit division.
    # Returns RAX, with the result.
    #
    def div dividend_val, divisor_val
      perform_division dividend_val, divisor_val, @fisk.rax
    end

    # Performs a 64-bit modulo.
    # Returns RDX, with the result.
    #
    def mod dividend_val, divisor_val
      perform_division dividend_val, divisor_val, @fisk.rdx
    end

    # Performs a division (used by div/mod).
    #
    # Returns the register passed.
    #
    # params:
    # - :register: The register returned; must be RAX (for div) or RDX (for mod).
    #
    # Reference: https://www.cs.uaf.edu/2006/fall/cs301/support/x86_64.
    #
    def perform_division dividend_val, divisor_val, register
      raise NotImplementedError unless dividend_val.memory?
      raise NotImplementedError unless divisor_val.memory?

      @fisk.mov @fisk.rdx, cast_to_fisk(0)            # x64 quirk; see reference
      @fisk.mov @fisk.rax, cast_to_fisk(dividend_val)

      temp_var do |divisor|
        @fisk.mov cast_to_fisk(divisor), cast_to_fisk(divisor_val)

        self.NUM2INT(@fisk.rax)
        self.NUM2INT(divisor)

        @fisk.div cast_to_fisk(divisor)
      end

      self.INT2NUM register

      register
    end
    private :perform_division

    def write_memory reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, val)
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def write_register reg, offset, val
      @fisk.mov(@fisk.m64(reg, offset), val)
    end

    def write_immediate reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.uimm(val))
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def write_immediate_to_reg reg, val
      @fisk.mov(reg, @fisk.uimm(val))
    end

    def read_to_reg src, offset
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.m64(src, offset))
        yield tmp
      end
    end

    def with_ref reg, offset = 0
      if reg.memory?
        offset = reg.displacement
        reg = reg.register
      end
      @fisk.with_register do |tmp|
        @fisk.lea(tmp, @fisk.m(reg, offset))
        yield tmp
      end
    end

    def write_to_mem dst, offset, src
      @fisk.mov(@fisk.m64(dst, offset), src)
    end

    def write dst, src
      dst = cast_to_fisk dst
      src = cast_to_fisk src

      if dst.memory? && (src.memory? || src.immediate?)
        @fisk.with_register do |tmp|
          @fisk.mov(tmp, src)
          @fisk.mov(dst, tmp)
        end
      else
        @fisk.mov(dst, src)
      end
    end

    def movsd reg, source
      @fisk.movsd reg, cast_to_fisk(source)
    end

    def break
      @fisk.int(@fisk.lit(3))
    end

    # Shift op1 right by op2
    def shr op1, op2
      @fisk.shr cast_to_fisk(op1), cast_to_fisk(op2)
    end

    # Shift op1 left by op2
    def shl op1, op2
      @fisk.shl cast_to_fisk(op1), cast_to_fisk(op2)
    end

    def test_flags obj, flags
      lhs = cast_to_fisk obj
      rhs = cast_to_fisk flags
      @fisk.test lhs, rhs
      @fisk.jz push_label  # else label
      finish_label = push_label
      yield if block_given?
      @fisk.jmp finish_label # finish label
      self
    end

    UINTPTR_MAX = 0xFFFFFFFFFFFFFFFF # on macos anyway
    RBIMPL_VALUE_FULL = UINTPTR_MAX

    class Conditional # :nodoc:
      def initialize lhs, jmp
        @lhs = lhs
        @jmp = jmp
      end

      def call fisk; @lhs.call(fisk); end
      def jump fisk, label; @jmp.call(fisk, label); end
    end

    def RB_STATIC_SYM_P sym_loc
      mask = 0xFF
      lhs = ->(fisk) {
        temp_var { |tv|
          tv.write sym_loc
          tv.and mask
          fisk.xor tv.to_register, fisk.imm(RUBY_SYMBOL_FLAG)
        }
      }

      jmp = ->(fisk, label) { fisk.jnz(label) }

      Conditional.new(lhs, jmp)
    end

    # Test if a flag has been set on the ep.
    def VM_ENV_FLAG_SET_P ep_loc, flag
      ->(fisk) {
        temp_var { |tv|
          ep = pointer(ep_loc)
          tv.write ep[VM_ENV_DATA_INDEX_FLAGS]
          tv.and(flag)
          fisk.test(tv.to_register, tv.to_register)
        }
      }
    end

    # Set the flag +flag+ on the ep
    def VM_ENV_FLAGS_SET ep_loc, flag
      temp_var { |tv|
        ep = pointer(ep_loc)
        tv.write ep[VM_ENV_DATA_INDEX_FLAGS]
        tv.or(flag)
        ep[VM_ENV_DATA_INDEX_FLAGS] = tv.to_register
      }
    end

    def RB_FIXNUM_P obj
      ->(fisk) { fisk.test(obj, fisk.uimm(RUBY_FIXNUM_FLAG)) }
    end
    alias :fixnum? :RB_FIXNUM_P

    def if lhs, op = nil, rhs = nil
      else_label = push_label # else label
      finish_label = push_label

      if op && rhs
        lhs = cast_to_fisk lhs
        rhs = cast_to_fisk rhs

        maybe_reg lhs do |op1|
          maybe_reg rhs, only_64: true do |op2|
            @fisk.cmp op1, op2
          end
        end
        @fisk.jg else_label # else label
      else
        if lhs.respond_to?(:call)
          lhs.call(@fisk)
        else
          @fisk.test lhs, lhs
        end
        if lhs.respond_to?(:jump)
          lhs.jump @fisk, else_label # else label
        else
          @fisk.jz else_label # else label
        end
      end
      yield if block_given?
      @fisk.jmp finish_label # finish label
      self
    end

    def if_eq lhs, rhs
      lhs = cast_to_fisk lhs
      rhs = cast_to_fisk rhs

      # The swap could be avoided in the lhs:imm64 sub-case, but keep it simple for now,
      # as it may be entirely removed in the future.
      #
      lhs, rhs = rhs, lhs if lhs.immediate? && !rhs.immediate?

      maybe_reg lhs do |op1|
        maybe_reg rhs, only_64: true do |op2|
          @fisk.cmp op1, op2
        end
      end
      @fisk.jne push_label # else label
      finish_label = push_label
      yield if block_given?
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

    def endif
      finish_label = pop_label
      else_label = pop_label
      @fisk.put_label else_label
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

    # Checks if the object at +loc+ is a special const. RAX is 0 if this is
    # *not* a special constant.
    def RB_SPECIAL_CONST_P loc
      is_immediate = push_label

      __ = @fisk
      reg = @fisk.rax
      @fisk.mov(reg, loc)
      @fisk.test(reg, reg)        # Is the parameter Qfalse?
      @fisk.cmovz(reg, @fisk.rsi) # If so, set the register to $rsi (it's non-zero)
      @fisk.jz(is_immediate)      # cmov didn't clear ZF, so we can jump if it's 0
      @fisk.test(reg, __.uimm(RUBY_IMMEDIATE_MASK))
      @fisk.jnz(is_immediate)
      @fisk.test(reg, __.imm(~Qnil))
      @fisk.jz(is_immediate)
      @fisk.mov(reg, __.uimm(0))
      @fisk.put_label(is_immediate.name)

      pop_label

      reg
    end

    # Finds the built-in type of the object stored in `loc`. The type is
    # placed in RAX
    def RB_BUILTIN_TYPE loc
      reg = @fisk.rax
      @fisk.mov(reg, loc)
      @fisk.mov(reg, @fisk.m64(reg, RBasic.offsetof("flags")))
      @fisk.and(reg, @fisk.uimm(RUBY_T_MASK))
      reg
    end

    # Create a temporary variable
    def temp_var name = "temp_var"
      tv = TemporaryVariable.new @fisk.register(name), Fiddle::TYPE_VOIDP, Fiddle::SIZEOF_VOIDP, 0, self

      if block_given?
        yield tv
        tv.release!
      else
        tv
      end
    end

    # Push a register on the machine stack
    def push_reg reg
      @fisk.push reg.to_register
      @cfunc_call_stack_depth += reg.size
    end

    # Pop a register on the machine stack
    def pop_reg reg
      @fisk.pop reg.to_register
      @cfunc_call_stack_depth -= reg.size
    end

    def return
      @fisk.ret
    end

    # Push a value on the stack
    def push val, name:, type: :unknown
      loc = @temp_stack.push name, type: type

      val = cast_to_fisk val

      if val.memory? || val.immediate?
        write loc, val
      else
        write loc, val.to_register
      end
    end

    def vm_get_ep ep_loc, level
      reg = ep_loc.to_register

      level.times do
        @fisk.mov(reg, @fisk.m64(reg, VM_ENV_DATA_INDEX_SPECVAL * Fiddle::SIZEOF_VOIDP))
        @fisk.and(reg, @fisk.imm(~0x03))
      end
    end

    # options:
    #  :call_reg: Specify an alternate register for the (long) function call; defaults
    #             to RAX.
    #
    def call_cfunc func_loc, params, auto_align: true, call_reg: Fisk::Registers::RAX
      raise NotImplementedError, "too many parameters" if params.length > 6
      raise "No function location" unless func_loc > 0

      align_cfunc_call(auto_align) do
        params.each_with_index do |param, i|
          case param
          when Integer
            @fisk.mov(Fisk::Registers::CALLER_SAVED[i], @fisk.uimm(param))
          when Fisk::Operand
            @fisk.mov(Fisk::Registers::CALLER_SAVED[i], param)
          when TemporaryVariable
            @fisk.mov(Fisk::Registers::CALLER_SAVED[i], param.to_register)
          when Proc
            param.call Fisk::Registers::CALLER_SAVED[i]
          else
            raise NotImplementedError
          end
        end

        @fisk.mov(call_reg, @fisk.uimm(func_loc))
          .call(call_reg)

        @fisk.rax
      end
    end

    # Align the stack, if needed.
    # Can be used to perform one alignment for multiple `cfunc` invocations, if
    # they don't misalign the stack.
    #
    # arguments:
    # - auto_align: true/false
    def align_cfunc_call auto_align, &block
      if @cfunc_call_stack_depth % 8 != 0
        message = "Auto alignment is supported only for a stack depth multiple of 8 (current: #{@cfunc_call_stack_depth})"
        raise NotImplementedError, message
      end

      # Watch out :) Must consider that 8 bytes are already pushed (RIP).
      #
      if auto_align && @cfunc_call_stack_depth % 16 == 0
        @fisk.push REG_BP.to_register

        result = yield

        @fisk.pop REG_BP.to_register

        result
      else
        yield
      end
    end

    def release_temp temp
      @fisk.release_register temp.reg
    end

    private

    def push_label n = "label"
      @label_count += 1
      label = "#{n} #{@label_count}"
      @labels.push label
      @fisk.label label
    end

    def pop_label
      @labels.pop
    end

    # If the operator is immediate, move to a register, otherwise, leave as is.
    # This is useful for instructions that don't support immediate for the given
    # operator, e.g. CMP $immediate, $other_op.
    #
    # params
    # - :only_64: move to register only if the immediate is 64 bits
    #
    def maybe_reg op, only_64: false
      if op.immediate? && (op.size == 64 || !only_64)
        @fisk.with_register do |tmp|
          @fisk.mov(tmp, op)
          yield tmp
        end
      else
        yield op
      end
    end

    def cast_to_fisk val
      case val
      when Fisk::Operand
        val
      when TemporaryVariable
        val.to_register
      else
        @fisk.imm(val)
      end
    end

    def find_size type
      type == Fiddle::TYPE_VOIDP ? Fiddle::SIZEOF_VOIDP : type.byte_size
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

      def []= idx, val
        @ec.write(self[idx], val)
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
        val = val.to_register if val.is_a?(TemporaryVariable)

        if val.is_a?(Fisk::Operand)
          if val.memory?
            @ec.write_memory @reg, @base + (idx * size), val
          elsif val.register?
            @ec.write_register @reg, @base + (idx * size), val
          else
            raise NotImplementedError
          end
        else
          @ec.write_immediate @reg, @base + (idx * size), val
        end
      end

      # Mutates this pointer.  Subtracts the size from itself.  Similar to
      # C's `--` operator
      def sub num = 1
        if num.is_a?(Fisk::Operand)
          @ec.sub reg, num
        else
          @ec.sub reg, size * num
        end
      end

      # Mutates this pointer.  Adds the size to itself.  Similar to
      # C's `++` operator
      def add num = 1
        @ec.add reg, size * num
      end

      def mult num
        @ec.mult reg, num
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
          if type.member(member).substruct?
            sub_type = type.member(member).type

            return Pointer.new(@reg, sub_type, sub_type.byte_size, @base + type.offsetof(member), @ec)
          end
        end

        return super unless type.members.include?(member)

        if read
          if block_given?
            @ec.read_to_reg(@reg, type.offsetof(member)) do |reg|
              yield reg
            end
          else
            if type.member(member).immediate?
              return Fisk::M64.new(@reg, @base + type.offsetof(member))
            else
              raise
              Array.new(reg, subtype.first, Fiddle::PackInfo::SIZE_MAP[subtype.first], @base + type.offsetof(member), @ec)
            end
          end

        else
          if v.is_a?(Pointer)
            @ec.write_to_mem @reg, type.offsetof(member), v.reg
          else
            if v.is_a?(Fisk::Operand)
              if v.memory?
                @ec.write_memory @reg, type.offsetof(member), v
              else
                @ec.write_register @reg, type.offsetof(member), v
              end
            else
              @ec.write_immediate @reg, type.offsetof(member), v.to_i
            end
          end
        end
      end
    end

    class TemporaryVariable < Pointer
      # Write something to the temporary variable
      def write operand
        if operand.is_a?(Fisk::Operand)
          @ec.write reg, operand
        else
          @ec.write_immediate_to_reg reg, operand
        end
      end

      def write_address_of arg
        @ec.load_address_in reg, arg
      end

      def and num
        @ec.and(reg, num)
      end

      def or num
        @ec.or(reg, num)
      end

      # Shift right
      def shr val
        @ec.shr reg, val
      end

      # Shift left
      def shl val
        @ec.shl reg, val
      end

      def to_register
        reg
      end

      def memory?; false; end
      def immediate?; false; end
      def register?; true; end
      def temp_register?; true; end

      # Release the temporary variable (say you are done using its value)
      def release!
        @ec.release_temp self
      end
    end
  end
end
