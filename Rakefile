require "digest/md5"
require "rake/testtask"
require "rake/clean"

require_relative "lib/tenderjit/ruby_interpreter_metadata_helper"

TEST_SUITE_DEFAULT_PREFIX='*'
DEBUG_LIBRARIES = %w[fiddle fisk worf odinflex]

test_files = RubyVM::INSTRUCTION_NAMES.grep_v(/^trace_/).each_with_object([]) do |name, files|
  # Since this instruction has been removed in 3.1, ignore it entirely.
  # This can be removed once/if the support for versions <= 3.0 is discontinued.
  next if name == 'reverse'

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
  files << test_file
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

# Launch an LLDB debug session.
#
# Don't forget to put an `rt.break`!
#
# - :test_suite_file: test suite file (mandatory)
#   if no `/` is in the param, then the file is searched as "test/**/#{test_suite_prefix}_test.rb";
#   in this case, only one file must be found.
#
task :debug, [:test_suite_file] => test_files + [:compile] do |_, args|
  test_suite_file =
    case args.test_suite_file
    when %r{/}
      args.test_suite_file
    else
      files = FileList["test/**/#{args.test_suite_file}_test.rb"]
      raise "Only one file must be found (found: #{files}" if files.size != 1
      files.first
    end

  library_dirs = %w[lib test] + DEBUG_LIBRARIES.map do |lib|
    "#{Gem::Specification.find_by_name(lib).gem_dir}/lib"
  end

  # WATCH OUT!!! lldb must be run outside a Bundler context, otherwise will be issues
  # with Bundler; in this case, the following errors will be printed (extract):
  #
  #   Process 314869 stopped and restarted: thread 1 received signal: SIGCHLD
  #   Exception `Bundler::GitError' at /path/to/bundler-2.2.30/lib/bundler/source/git/git_proxy.rb:221 - The git source https://github.com/tenderlove/fisk.git is not yet checked out. Please run `bundle install` before trying to start your application
  #   Exception `Bundler::GitError' at /path/to/bundler-2.2.30/lib/bundler/source/git/git_proxy.rb:221 - The git source https://github.com/tenderlove/worf.git is not yet checked out. Please run `bundle install` before trying to start your application
  #   (similar errors)
  #
  # lldb options:
  # -o: run given command on start
  #
  # Ruby options:
  # -d: debug
  # -v: verbose mode
  # -I: load paths
  #
  Bundler.with_unbundled_env do
    command = "lldb -o run ruby -- -d -v -I #{library_dirs.join(":")} #{test_suite_file}"
    system command
  end
end

CLEAN.include "lib/tenderjit/ruby"
