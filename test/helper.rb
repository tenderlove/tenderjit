ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tendertools/mach-o"
require "tendertools/dwarf"
require "tendertools/ar"
require "rbconfig"
require "fiddle"

module TenderTools
  class Test < Minitest::Test
    include Fiddle

    module Hacks
      include Fiddle

      class Fiddle::Function
        def to_proc
          this = self
          lambda { |*args| this.call(*args) }
        end
      end unless Function.method_defined?(:to_proc)

      func_name = "_dyld_image_count"
      ptr = Fiddle::Handle::DEFAULT[func_name]
      func = Function.new ptr, [], TYPE_INT32_T, name: func_name
      define_singleton_method(func_name, &func.to_proc)

      func_name = "_dyld_get_image_name"
      ptr = Fiddle::Handle::DEFAULT[func_name]
      func = Function.new ptr, [TYPE_INT32_T], TYPE_CONST_STRING, name: func_name
      define_singleton_method(func_name, &func.to_proc)

      func_name = "_dyld_get_image_vmaddr_slide"
      ptr = Fiddle::Handle::DEFAULT[func_name]
      func = Function.new ptr, [TYPE_INT32_T], TYPE_INTPTR_T, name: func_name
      define_singleton_method(func_name, &func.to_proc)

      def self.slide
        executable = RbConfig.ruby
        Hacks._dyld_image_count.times do |i|
          name = Hacks._dyld_get_image_name(i)
          if executable == name
            return Hacks._dyld_get_image_vmaddr_slide(i)
          end
        end
      end
    end
  end
end
