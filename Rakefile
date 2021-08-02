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

require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose = true
  t.warning = true
end

task :default => 'lib/tendertools/dwarf/constants.rb'
task :test => test_files
