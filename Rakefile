require "digest/md5"
require "rake/testtask"
require "rake/clean"

require_relative "lib/tenderjit/ruby_interpreter_metadata_helper"

file 'lib/tendertools/dwarf/constants.rb' => ['lib/tendertools/dwarf/constants.yml', 'lib/tendertools/dwarf/constants.erb'] do |t|
  require 'psych'
  require 'erb'
  constants = Psych.load_file t.prereqs.first
  erb = ERB.new File.read(t.prereqs[1]), trim_mode: '-'
  File.write t.name, erb.result(binding)
end

test_files = RubyVM::INSTRUCTION_NAMES.grep_v(/^trace_/).map do |name|
  test_file = "test/instructions/#{name}_test.rb"
  file test_file do |t|
    File.open(test_file, "w") do |f|
      f.write <<~eorb
# frozen_string_literal: true

require "helper"

class TenderJIT
  class #{name.split('_').map(&:capitalize).join}Test < JITTest
    def test_#{name}
      skip "Please implement #{name}!"
    end
  end
end
      eorb
    end
  end
  test_file
end

folder = TenderJIT::RubyInterpreterMetadataHelper.fingerprint

gen_files = %w{ constants structs symbols }.map { |name|
  "lib/tenderjit/ruby/#{folder}/#{name}.rb"
}

file gen_files.first do |t|
  FileUtils.mkdir_p("lib/tenderjit/ruby/#{folder}")
  ruby %{-I lib misc/build-ruby-internals.rb #{folder}}
end

task :compile => gen_files.first

Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose = true
  t.warning = true
end

task :default => 'lib/tendertools/dwarf/constants.rb'
task :test => test_files + [:compile]

CLEAN.include "lib/tenderjit/ruby"
