file 'lib/dwarf/constants.rb' => ['lib/dwarf/constants.yml', 'lib/dwarf/constants.erb'] do |t|
  require 'psych'
  require 'erb'
  constants = Psych.load_file t.prereqs.first
  erb = ERB.new File.read(t.prereqs[1]), trim_mode: '-'
  File.write t.name, erb.result(binding)
end

task :default => 'lib/dwarf/constants.rb'
