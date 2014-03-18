module RRRSpec
  module Client
    class CLIAPIHandler
      def initialize(command, options)
        @command = command
        @options = options
      end

      def open(transport)
        send(@command, transport)
      end

      def close(transport)
        EM.stop_event_loop
      end

      def start(transport)
        builder = TasksetBuilder.new(transport)
        builder.packaging_dir = RRRSpec.config.packaging_dir
        builder.rsync_remote_path = RRRSpec.config.rsync_remote_path
        builder.rsync_options = RRRSpec.config.rsync_options
        builder.unknown_spec_timeout_sec = @options[:unknown_spec_timeout_sec] || RRRSpec.config.unknown_spec_timeout_sec
        builder.least_timeout_sec = @options[:least_timeout_sec] || RRRSpec.config.least_timeout_sec
        builder.average_multiplier = @options[:average_multiplier] || RRRSpec.config.average_multiplier
        builder.hard_timeout_margin_sec = @options[:hard_timeout_margin_sec] || RRRSpec.config.hard_timeout_margin_sec

        builder.rsync_name = @options[:rsync_name] || RRRSpec.config.rsync_name || ENV['USER']
        builder.worker_type = @options[:worker_type] || RRRSpec.config.worker_type
        builder.max_workers = @options[:max_workers] || RRRSpec.config.max_workers
        builder.max_trials = @options[:max_trials] || RRRSpec.config.max_trials
        builder.taskset_class = RRRSpec.config.taskset_class
        builder.setup_command = RRRSpec.config.setup_command
        builder.slave_command = RRRSpec.config.slave_command
        builder.spec_files = RRRSpec.config.spec_files
        taskset_ref = builder.create_and_start

        puts taskset_ref[1]
        transport.close
      end

      def cancel(transport)
        taskset_id = ARGV[0]
        if taskset_id
          taskset_ref = [:taskset, taskset_id.to_i]
          transport.sync_call(:cancel_taskset, taskset_ref)
          transport.close
        else
          raise "Specify the taskset id"
        end
      end

      def cancelall(transport)
        rsync_name = ARGV[0]
        if rsync_name
          transport.sync_call(:cancel_user_taskset, rsync_name)
          transport.close
        else
          raise "Specify the rsync name"
        end
      end

      def actives(transport)
        # TODO
        transport.close
      end

      def nodes(transport)
        # TODO
        transport.close
      end

      def waitfor(transport)
        taskset_id = ARGV[0]
        if taskset_id
          @exit_if_taskset_finished = true
          taskset_ref = [:taskset, taskset_id.to_i]
          transport.sync_call(:listen_to_taskset, taskset_ref)
          status = transport.sync_call(:query_taskset_status, taskset_ref)
          if ['cancelled', 'failed', 'succeeded'].include?(status)
            transport.close
          end
        else
          raise "Specify the taskset id"
        end
      end

      def show(transport)
        # TODO
        transport.close
      end

      def taskset_updated(transport, timestamp, taskset_ref, h)
        if @exit_if_taskset_finished && h['finished_at'].present?
          transport.close
        end
      end

      def task_updated(transport, timestamp, task_ref, h)
        # Do nothing
      end

      def trial_created(transport, timestamp, trials_ref, task_ref, slave_ref, created_at)
        # Do nothing
      end

      def trial_updated(transport, timestamp, trial_ref, task_ref, finished_at, trial_status, passed, pending, failed)
        # Do nothing
      end

      def worker_log_created(transport, timestamp, worker_log_ref, worker_name)
        # Do nothing
      end

      def worker_log_updated(transport, timestamp, worker_log_ref, h)
        # Do nothing
      end

      def slave_created(transport, timestamp, slave_ref, slave_name)
        # Do nothing
      end

      def slave_updated(transport, timestamp, slave_ref, h)
        # Do nothing
      end
    end

    module CLI
      COMMANDS = {
        'start' => 'start RRRSpec',
        'cancel' => 'cancel the taskset',
        'cancelall' => 'cancel all tasksets whose rsync name is specified name',
        'actives' => 'list up the active tasksets',
        'nodes' => 'list up the active nodes',
        'waitfor' => 'wait for the taskset',
        'show' => 'show the result of the taskset',
      }

      module_function

      def run
        options, command, command_options = parse_options
        setup(options)

        if COMMANDS.include?(command)
          EM.run do
            WebSocketTransport.new(
              CLIAPIHandler.new(command, command_options),
              RRRSpec.config.master_url,
              auto_reconnect: true,
            )
          end
        else
          nocommand(command)
        end
      end

      def parse_options
        options = {}
        command = nil
        command_options = {}

        OptionParser.new do |opts|
          opts.on('-c', '--config FILE') { |file| options[:config] = file }
        end.order!

        command = ARGV.shift
        case command
        when 'start'
          OptionParser.new do |opts|
            opts.on('--key-only') { |v| command_options[:key_only] = v }
            opts.on('--unknown-spec-timeout-sec SECOND', OptionParser::DecimalInteger) do |second|
              command_options[:unknown_spec_timeout_sec] = second
            end
            opts.on('--least-timeout-sec SECOND', OptionParser::DecimalInteger) do |second|
              command_options[:least_timeout_sec] = second
            end
            opts.on('--average-multiplier NUM', OptionParser::DecimalInteger) do |num|
              command_options[:average_multiplier] = num
            end
            opts.on('--hard-timeout-margin-sec SECOND', OptionParser::DecimalInteger) do |num|
              command_options[:hard_timeout_margin_sec] = second
            end
            opts.on('--rsync-name NAME') { |name| command_options[:rsync_name] = name }
            opts.on('--worker-type TYPE') { |type| command_options[:worker_type] = type }
            opts.on('--max-workers NUM', OptionParser::DecimalInteger) do |num|
              command_options[:max_workers] = num
            end
            opts.on('--max-trials NUM', OptionParser::DecimalInteger) do |num|
              command_options[:max_trials] = num
            end
          end.order!
        when 'cancel'
        when 'cancelall'
        when 'actives'
        when 'nodes'
        when 'waitfor'
        when 'show'
          OptionParser.new do |opts|
            opts.on('--failure-exit-code NUM', OptionParser::DecimalInteger) do |num|
              command_options[:failure_exit_code] = num
            end
          end.order!
        end

        return options, command, command_options
      end

      def setup(options)
        RRRSpec.application_type = :client
        RRRSpec.config = ClientConfig.new
        files = if options[:config].present?
                  [options[:config]]
                else
                  ['.rrrspec', '.rrrspec-local', File.expand_path('~/.rrrspec')]
                end
        files.each do |path|
          load(path) if File.exists?(path)
        end
      end

      def nocommand(command)
      end
    end
  end
end
