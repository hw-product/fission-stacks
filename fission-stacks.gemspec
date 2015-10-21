$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__)) + '/lib/'
require 'fission-stacks/version'
Gem::Specification.new do |s|
  s.name = 'fission-stacks'
  s.version = Fission::Stacks::VERSION.version
  s.summary = 'Fission Stacks'
  s.author = 'Heavywater'
  s.email = 'fission@hw-ops.com'
  s.homepage = 'http://github.com/hw-product/fission-stacks'
  s.description = 'Fission Stacks'
  s.require_path = 'lib'
  s.add_runtime_dependency 'fission', '>= 0.2.4', '< 1.0.0'
  s.add_runtime_dependency 'fission-data', '>= 0.2.11', '< 1.0.0'
  s.files = Dir['{lib}/**/**/*'] + %w(fission-stacks.gemspec README.md CHANGELOG.md)
end
