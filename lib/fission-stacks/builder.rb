require 'fission-stacks'

module Fission
  module Stacks
    class Builder < Jackal::Stacks::Builder

      # Build or update stacks
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          ctn = remote_process
          asset = asset_store.get(payload.get(:data, :stacks, :asset))
          remote_asset = '/tmp/asset.zip'
          remote_dir = '/tmp/unpacked'
          ctn.push_file(asset, remote_asset)
          ctn.exec!("mkdir -p #{remote_dir}")
          ctn.exec!("unzip #{remote_asset} -d #{remote_dir}")
          begin
            stack = stacks_api.stacks.get(payload.get(:data, :stacks, :name))
          rescue => e
            debug "Failed to fetch defined stack name: #{e.class} - #{e}"
            stack = nil
          end
          begin
            if(stack)
              info "Stack currently exists. Applying update [#{stack}]"
              run_stack(ctn, payload, remote_dir, :update)
              payload.set(:data, :stacks, :updated, true)
            else
              info "Stack does not exist. Building new stack [#{payload.get(:data, :stacks, :name)}]"
              init_provider(provider)
              run_stack(ctn, payload, remote_dir, :create)
              payload.set(:data, :stacks, :created, true)
            end
          rescue => e
            # log error
            raise
          end
        end
      end

      # Always allowed in fission. Let routing rules handle entry
      def allowed?(*_)
        true
      end

      # Run action on stack
      #
      # @param ctn [Fission::Utils::RemoteProcess]
      # @return [Hash] payload
      def run_stack(ctn, payload, directory, action)
        unless([:create, :update].include?(action.to_sym))
          abort ArgumentError.new("Invalid action argument `#{action}`. Expecting `create` or `update`!")
        end
        ctn.exec!('bundle install', :cwd => directory)
        stack_name = payload.get(:data, :stacks, :name)

        event!(:info, :info => "Starting stack #{action} - #{stack_name}!", :message_id => payload[:message_id])

        stream = Fission::Utils::RemoteProcess::QueueStream.new
        future = Zoidberg::Future.new do
          begin
            ctn.exec(
              "bundle exec sfn #{action} --file #{payload.get(:data, :stacks, :template)}",
              :stream => stream,
              :cwd => directory,
              :environment => api_environment_variables,
              :timeout => 3600 # TODO: This will probably need to be tunable!
            )
          rescue => e
            error "Stack #{action} failed (ID: #{payload[:message_id]}): #{e.class} - #{e}"
            debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
            Fission::Utils::RemoteProcess::Result(-1, "Build failed (ID: #{uuid}): #{e.class} - #{e}")
          ensure
            stream.write :complete
          end
        end

        until((lines = stream.pop) == :complete)
          lines.split("\n").each do |line|
            line = line.sub(/^\[.+?\]/, '').strip
            next if line.empty?
            debug "Log line: #{line}"
            event!(:info, :info => line, :message_id => payload[:message_id])
          end
        end

        result = future.value
        ctn.terminate

        if(result && result.success?)
          event!(:info, :info => "Stack #{action} completed - #{stack_name}!", :message_id => payload[:message_id])
        else
          error "Stack #{action} failed for stack #{stack_name}"
          error "Stack #{action} failed with exit status of `#{result.exit_code}`"
          error = Fission::Error::RemoteProcessFailed.new("Stack #{action} failed - Exit code: #{result.exit_code}")
          raise error
        end
      end

      def api_environment_variables
        Smash.new.tap do |env|
          env['SFN_PROVIDER'] = config.get(:orchestration, :api, :provider)
          config.fetch(:orchestration, :api, :credentials, {}).each do |k,v|
            env[k.upcase] = v
          end
        end
      end

    end
  end
end
