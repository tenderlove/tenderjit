require "fiddle"
require "jit_buffer"

class TenderJIT
  module Util
    jit = JITBuffer.new 4096

    bytes = [0x48, 0xc7, 0xc0, 0x2c, 0x00, 0x00, 0x00, # x86_64 mov rax, 0x2b
             0xc3,                                     # x86_64 ret
             0xeb, 0xf6,                               # x86 jmp
             0x80, 0xd2,                               # ARM movz X11, 0x7b7
             0x60, 0x05, 0x80, 0xd2,                   # ARM movz X0, #0x2b
             0xc0, 0x03, 0x5f, 0xd6]                   # ARM ret

    jit.writeable!
    jit.write bytes.pack("C*")
    jit.executable!
    func = Fiddle::Function.new(jit.to_i + 8, [], Fiddle::TYPE_INT)

    PLATFORM = func.call == 0x2c ? :x86_64 : :arm64

    module ClassGen
      def self.pos *names
        Class.new do
          attr_reader(*names)
          sig = names.map { "#{_1} = nil" }.join(", ")
          init = names.map { "@#{_1} = #{_1}" }.join(";")
          class_eval("def initialize #{sig}; super(); #{init}; end")
        end
      end
    end
  end
end
