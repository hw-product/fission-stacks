require 'fission'
require 'jackal-stacks'

module Fission
  module Stacks
    autoload :RemoteBuilder, 'fission-stacks/remote_builder'
  end
end

require 'fission/version'

Fission.service(
  :stacks,
  :description => 'Manage stacks',
  :configuration => {
    :template => {
      :description => 'Template name to build',
      :type => :string
    },
    :environment => {
      :description => 'Custom environment variables',
      :type => :hash
    }
  }
)
