class TenderJIT
  class ISEQCompiler
    module Frames
      class Virtual
        attr_reader :iseq, :type, :_self, :specval, :cref_or_me, :pc, :argv, :local_size

        def initialize iseq, type, _self, specval, cref_or_me, pc, argv, local_size
          @iseq       = iseq
          @type       = type
          @_self      = _self
          @specval    = specval
          @cref_or_me = cref_or_me
          @pc         = pc
          @argv       = argv
          @local_size = local_size
        end

        def push rt
          new_sp = nil

          ec_ptr = rt.pointer REG_EC, type: RbExecutionContextT
          cfp_ptr = rt.pointer REG_CFP, type: RbControlFrameStruct

          temp = rt.temp_var
          temp.write_address_of argv
          sp = temp

          sp_ptr = rt.pointer sp

          # rb_control_frame_t *const cfp = RUBY_VM_NEXT_CONTROL_FRAME(ec->cfp);
          cfp_ptr.sub # like -- in C

          local_size.times do |i|
            sp_ptr[i] = Qnil
          end

          # /* setup ep with managing data */
          # *sp++ = cref_or_me; /* ep[-2] / Qnil or T_IMEMO(cref) or T_IMEMO(ment) */
          # *sp++ = specval     /* ep[-1] / block handler or prev env ptr */;
          # *sp++ = type;       /* ep[-0] / ENV_FLAGS */
          sp_ptr[local_size + 0] = cref_or_me
          write_specval rt, sp_ptr
          sp_ptr[local_size + 2] = type

          temp.write_address_of temp[3 + local_size]
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
          cfp_ptr.self = _self
          cfp_ptr.block_code = 0

          # ec->cfp = cfp;
          ec_ptr.cfp = cfp_ptr
          temp.release!
        end

        def write_specval rt, sp_ptr
          specval.write(rt) do |val|
            sp_ptr[local_size + 1] = val
          end
        end
      end

      class ISeq < Virtual
        def initialize iseq, _self, specval, cref_or_me, pc, argv, local_size
          type = VM_FRAME_MAGIC_METHOD | VM_ENV_FLAG_LOCAL
          super(iseq, type, _self, specval, cref_or_me, pc, argv, local_size)
        end
      end

      class CFunc < Virtual
        def initialize _self, specval, cref_or_me, argv
          iseq       = 0
          type       = VM_FRAME_MAGIC_CFUNC | VM_FRAME_FLAG_CFRAME | VM_ENV_FLAG_LOCAL
          pc         = 0
          local_size = 0
          super(iseq, type, _self, specval, cref_or_me, pc, argv, local_size)
        end
      end

      class BMethod < Virtual
        def initialize iseq, _self, specval, cref_or_me, pc, argv, local_size
          type = VM_FRAME_MAGIC_BLOCK | VM_FRAME_FLAG_BMETHOD,

          super(iseq, type, _self, specval, cref_or_me, pc, argv, local_size)
        end
      end
    end

    module SpecVals
      class Null
        def write rt
          yield 0
        end
      end

      NULL = Null.new

      class PreviousEP
        def initialize ep
          @ep = ep.to_i
        end

        def write rt
          yield VM_GUARDED_PREV_EP(@ep)
        end

        private

        def VM_GUARDED_PREV_EP ep
          ep | 0x01
        end
      end
    end
  end
end
