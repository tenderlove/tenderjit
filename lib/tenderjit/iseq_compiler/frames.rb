class TenderJIT
  class ISEQCompiler
    module Frames
      class Virtual
        attr_reader :iseq, :type, :_self, :specval, :cref_or_me, :pc, :local_size, :temp_stack

        def initialize iseq, type, _self, specval, cref_or_me, pc, local_size, temp_stack
          @iseq       = iseq
          @type       = type
          @_self      = _self
          @specval    = specval
          @cref_or_me = cref_or_me
          @pc         = pc
          @local_size = local_size
          @temp_stack = temp_stack
        end

        def push rt
          new_sp = nil

          ec_ptr = rt.pointer REG_EC, type: RbExecutionContextT
          cfp_ptr = rt.pointer REG_CFP, type: RbControlFrameStruct

          temp =  if _self.temp_register?
                    _self
                  else
                    new_self = rt.temp_var("self")
                    new_self.write self._self
                    new_self
                  end

          # Write `self` to the next frame.  Frames grow down, so we subtract
          # the size of the frame from the offset of "self" then set self to
          # that value
          next_frame_loc = -RbControlFrameStruct.byte_size
          self_offset = RbControlFrameStruct.offsetof("self")

          rt.write_register(REG_CFP, next_frame_loc + self_offset, temp.to_register)

          # Fill in the local table
          local_size.times do
            rt.write temp_stack.push(:local), Qnil
          end

          # Set up the stack values for the callee frame.  It's important we
          # set these values before pushing the new CFP.  Captured blocks need
          # to set the block code on the *caller* frame before we push a new
          # frame.
          #
          # /* setup ep with managing data */
          # *sp++ = cref_or_me; /* ep[-2] / Qnil or T_IMEMO(cref) or T_IMEMO(ment) */
          # *sp++ = specval     /* ep[-1] / block handler or prev env ptr */;
          # *sp++ = type;       /* ep[-0] / ENV_FLAGS */
          rt.write temp_stack.push(:cref), cref_or_me
          write_specval rt, temp_stack.push(:specval)
          rt.write temp_stack.push(:env_flags), type

          # rb_control_frame_t *const cfp = RUBY_VM_NEXT_CONTROL_FRAME(ec->cfp);
          cfp_ptr.sub # like -- in C

          temp.write_address_of(temp_stack + 0)
          new_sp = temp

          # /* setup new frame */
          # *cfp = (const struct rb_control_frame_struct) {
          #     .pc         = pc,
          #     .sp         = sp,
          #     .iseq       = iseq,
          #     .self       = self,
          #     .ep         = sp - 1,
          #     .block_code = NULL,
          #     .__bp__     = sp
          # };
          cfp_ptr.pc = pc
          cfp_ptr.sp     = new_sp
          cfp_ptr.__bp__ = new_sp

          new_sp.sub
          cfp_ptr.ep     = new_sp

          cfp_ptr.iseq = iseq
          cfp_ptr.block_code = 0

          # ec->cfp = cfp;
          ec_ptr.cfp = cfp_ptr
          temp.release!
        end

        def write_specval rt, stack_loc
          specval.write_specval(rt) do |val|
            rt.write stack_loc, val
          end
        end
      end

      class Block < Virtual
        def initialize iseq, _self, specval, cref_or_me, pc, local_size, ts
          type = VM_FRAME_MAGIC_BLOCK
          super(iseq, type, _self, specval, cref_or_me, pc, local_size, ts)
        end
      end

      class ISeq < Virtual
        def initialize iseq, _self, specval, cref_or_me, pc, local_size, temp_stack
          type = VM_FRAME_MAGIC_METHOD | VM_ENV_FLAG_LOCAL
          super(iseq, type, _self, specval, cref_or_me, pc, local_size, temp_stack)
        end
      end

      class CFunc < Virtual
        def initialize _self, specval, cref_or_me, ts
          iseq       = 0
          type       = VM_FRAME_MAGIC_CFUNC | VM_FRAME_FLAG_CFRAME | VM_ENV_FLAG_LOCAL
          pc         = 0
          local_size = 0
          super(iseq, type, _self, specval, cref_or_me, pc, local_size, ts)
        end
      end

      class BMethod < Virtual
        def initialize iseq, _self, specval, cref_or_me, pc, local_size, ts
          type = VM_FRAME_MAGIC_BLOCK | VM_FRAME_FLAG_BMETHOD,

          super(iseq, type, _self, specval, cref_or_me, pc, local_size, ts)
        end
      end
    end

    module SpecVals
      class Null
        def write_specval rt
          yield 0
        end
      end

      NULL = Null.new

      class PreviousEP
        def initialize ep
          @ep = ep.to_i
        end

        def write_specval rt
          yield VM_GUARDED_PREV_EP(@ep)
        end

        private

        def VM_GUARDED_PREV_EP ep
          ep | 0x01
        end
      end

      class CapturedBlock
        def initialize rb, blockiseq
          @rb        = rb
          @blockiseq = blockiseq
        end

        # It's important that this gets called before the frame is pushed.
        # We need to write the block code reference to the *current* frame,
        # and the specval needs to be added to the stack of the *callee* frame
        def write_specval rt
          cfp_ptr = rt.pointer(REG_CFP, type: RbControlFrameStruct)
          cfp_ptr.block_code = @blockiseq
          rt.with_ref(cfp_ptr.self) do |self_ref|
            VM_BH_FROM_ISEQ_BLOCK(rt, self_ref)
            yield self_ref
          end
        end

        private

        def VM_BH_FROM_ISEQ_BLOCK rt, self_ref
          rt.or self_ref, 0x01
        end
      end
    end
  end
end
