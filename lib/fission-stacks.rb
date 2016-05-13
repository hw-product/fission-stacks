require 'fission'
require 'jackal-stacks'

require 'fission-stacks/remote_builder'
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
