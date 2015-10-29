require 'fission-stacks'

module Fission
  module Stacks
    class RemoteBuilder < Jackal::Stacks::Builder

      # Build or update stacks
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          unless(payload.get(:data, :stacks, :name))
            payload.set(:data, :stacks, :name, stack_name(payload))
          end
          unless(payload.get(:data, :stacks, :template))
            payload.set(:data, :stacks, :template, config.fetch(:template, 'infrastructure'))
          end
          ctn = remote_process
          asset = asset_store.get(payload.get(:data, :stacks, :asset))
          remote_asset = '/tmp/asset.zip'
          remote_dir = '/tmp/unpacked'
          ctn.push_file(File.open(asset.path, 'rb'), remote_asset)
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
              info "Stack currently exists. Applying update [#{stack.name}]"
              event!(:info, :info => "Found existing stack. Applying update. [#{stack.name}]", :message_id => payload[:message_id])
              run_stack(ctn, payload, remote_dir, :update)
              payload.set(:data, :stacks, :updated, true)
              event!(:info, :info => "Stack update complete! [#{stack.name}]", :message_id => payload[:message_id])
            else
              stack_name = payload.get(:data, :stacks, :name)
              info "Stack does not exist. Building new stack [#{stack_name}]"
              event!(:info, :info => "Building new stack. [#{stack_name}]", :message_id => payload[:message_id])
              run_stack(ctn, payload, remote_dir, :create)
              payload.set(:data, :stacks, :created, true)
              event!(:info, :info => "Stack build complete! [#{stack_name}]", :message_id => payload[:message_id])
            end
          rescue => e
            error "Failed to apply stack action! #{e.class}: #{e}"
            debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
            raise
          end
          job_completed(:stacks, payload, message)
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
        ctn.exec!('bundle install', :cwd => directory, :timeout => 120)
        stack_name = payload.get(:data, :stacks, :name)

        event!(:info, :info => "Starting stack #{action} - #{stack_name}!", :message_id => payload[:message_id])

        stream = Fission::Utils::RemoteProcess::QueueStream.new
        future = Zoidberg::Future.new do
          begin
            ctn.exec(
              "bundle exec sfn #{action} #{stack_name} --defaults --no-interactive-parameters --file #{payload.get(:data, :stacks, :template)}",
              :stream => stream,
              :cwd => directory,
              :environment => api_environment_variables.merge(
                'HOME' => directory,
                'USER' => 'SparkleProvision'
              ),
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

      # @return [Hash] API environment variables for remote process
      def api_environment_variables
        Smash.new.tap do |env|
          ac = api_config
          env['SFN_PROVIDER'] = ac[:provider]
          ac.fetch(:credentials, {}).each do |k,v|
            env[k.upcase] = v
          end
        end
      end

    end
  end
end

Fission.register(:stacks, :remote_builder, Fission::Stacks::RemoteBuilder)
