require 'fission-stacks'

module Fission
  module Stacks
    class RemoteBuilder < Jackal::Stacks::Builder

      # Build or update stacks
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          unless(payload.get(:data, :stacks, :template))
            payload.set(:data, :stacks, :template, config.fetch(:template, 'infrastructure'))
          end
          unless(payload.get(:data, :stacks, :name))
            payload.set(:data, :stacks, :name, stack_name(payload))
          end
          ctn = remote_process
          asset = asset_store.get(payload.get(:data, :stacks, :asset))
          asset.flush
          remote_asset = '/tmp/asset.zip'
          remote_dir = '/tmp/unpacked'
          ctn.push_file(File.open(asset.path, 'rb'), remote_asset)
          ctn.exec!("mkdir -p #{remote_dir}")
          ctn.exec!("unzip #{remote_asset} -d #{remote_dir}")
          stack_name = payload.get(:data, :stacks, :name)
          info "Starting stack processing for message #{message} -> Stack: #{stack_name}"
          event!(:info, :info => "Starting stack processing on #{stack_name}", :message_id => payload[:message_id])
          result = run_stack(ctn, payload, remote_dir)
          payload.set(:data, :stacks, result, true)
          event!(:info, :info => "Completed stack #{result} on #{stack_name}", :message_id => payload[:message_id])
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
      # @param payload [Hash]
      # @param directory [String]
      # @return [Symbol] :create or :update
      def run_stack(ctn, payload, directory)
        env_vars = build_environment_variables(payload)
        stack_name = payload.get(:data, :stacks, :name)
        event!(:info, :info => 'Installing local bundle', :message_id => payload[:message_id])

        result = ctn.exec('bundle install',
          :cwd => directory,
          :timeout => 120,
          :environment => env_vars
        )
        if(result.success?)
          event!(:info, :info => 'Bundle installation complete!', :message_id => payload[:message_id])
        else
          result.output.rewind
          result.output.read.split("\n").each do |line|
            event!(:info, :info => line, :message_id => payload[:message_id])
          end
          event!(:info, :info => 'Bundle installation failed!', :message_id => payload[:message_id])
          raise 'Failed to install user bundle'
        end

        result = ctn.exec("sfn describe #{stack_name}",
          :cwd => directory,
          :environment => env_vars
        )
        if(result.success?)
          action = 'update'
        else
          action = 'create'
        end

        event!(:info, :info => "Starting stack #{action} - #{stack_name}!", :message_id => payload[:message_id])

        stream = Fission::Utils::RemoteProcess::QueueStream.new
        future = Zoidberg::Future.new do
          begin
            ctn.exec(
              "bundle exec sfn #{action} #{stack_name} --defaults --no-interactive-parameters --file #{payload.get(:data, :stacks, :template)} --yes",
              :stream => stream,
              :cwd => directory,
              :environment => env_vars.merge(
                'HOME' => directory,
                'USER' => 'SparkleProvision'
              ),
              :timeout => 3600 # TODO: This will probably need to be tunable!
            )
          rescue => e
            error "Stack #{action} failed (ID: #{payload[:message_id]}): #{e.class} - #{e}"
            debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
            Fission::Utils::RemoteProcess::Result.new(-1, "Build failed (ID: #{payload[:message_id]}): #{e.class} - #{e}")
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
        action
      end

      def build_environment_variables(payload)
        base = common_environment_variables(payload)
        base.merge!(config.fetch(:environment, Smash.new).to_smash)
        base.merge!(api_environment_variables)
        base
      end

      # @return [Hash] API environment variables for remote process
      def api_environment_variables
        ac = api_config
        Smash.new.tap do |env|
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
