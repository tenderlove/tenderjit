require "tenderjit"

module RubyVM::RJIT
  Compiler.prepend(Module.new {
    def compile iseq, cfp
      compiler = TenderJIT::Compiler.new iseq
      compiler.compile cfp
    end
  })
end

RubyVM::RJIT.resume
