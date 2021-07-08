Gem::Specification.new do |s|
  s.name        = "tenderjit"
  s.version     = "1.0.0"
  s.summary     = "A JIT for Ruby written in Ruby"
  s.description = "Yet another JIT for Ruby written in Ruby."
  s.authors     = ["Aaron Patterson"]
  s.email       = "tenderlove@ruby-lang.org"
  s.files       = `git ls-files -z`.split("\x0")
  s.test_files  = s.files.grep(%r{^test/})
  s.homepage    = "https://github.com/tenderlove/tenderjit"
  s.license     = "Apache-2.0"

  s.add_runtime_dependency("worf", "~> 1.0")
  s.add_runtime_dependency("odinflex", "~> 1.0")
  s.add_runtime_dependency("fisk", "~> 2.0")
  s.add_runtime_dependency("fiddle", "~> 1.0")
  s.add_development_dependency("rake", "~> 13.0")
  s.add_development_dependency("minitest", "~> 5.14")
  s.add_development_dependency("crabstone", "~> 4.0")
end
