require "tenderjit"

module RubyVM::RJIT
  TJ = TenderJIT.new
  Compiler.prepend(Module.new {
    def compile iseq, cfp
      TJ.compile iseq, cfp
    end
  })
end

RubyVM::RJIT.resume
