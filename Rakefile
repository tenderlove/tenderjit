require "digest/md5"
require "rake/testtask"
require "rake/clean"

require_relative "lib/tenderjit/ruby_interpreter_metadata_helper"

TEST_SUITE_DEFAULT_PREFIX='*'

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

task :default => 'lib/tendertools/dwarf/constants.rb'

# Run the test suites.
#
# Test suites are assumed to be under any subdirectory level of `test`, and with
# a filename ending with `_test.rb`.
#
# Arguments:
#
# - :test_suite_prefix: test suite prefix, in glob format; can include slashes.
#   defaults to TEST_SUITE_DEFAULT_PREFIX.
#   example: `foo/bar` will match `test/**/foo/bar_test.rb`
# - :test_bare_name: test name (without prefix); if nil, all the UTs are run.
#   defaults to run all the UTs.
#   example: `empty_array` will run `test_empty_array`
#
task :test, [:test_suite_prefix, :test_bare_name] => test_files + [:compile] do |_, args|
  Rake::TestTask.new do |t|
    test_suite_prefix = args.test_suite_prefix || TEST_SUITE_DEFAULT_PREFIX

    t.libs << "test"
    t.test_files = FileList["test/**/#{test_suite_prefix}_test.rb"]

    # This is somewhat hacky, but TestTask doesn't leave many... options 😬
    # See source (`rake-$version/lib/rake/testtask.rb`).
    #
    t.options = "-ntest_#{args.test_bare_name}" if args.test_bare_name

    t.verbose = true
    t.warning = true
  end
end

CLEAN.include "lib/tenderjit/ruby"
