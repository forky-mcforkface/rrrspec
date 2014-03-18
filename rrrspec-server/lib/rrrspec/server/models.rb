module RRRSpec
  module Server
    module TypeIDReferable
      extend ActiveSupport::Concern

      module ClassMethods
        def from_ref(ref)
          label, i = ref
          raise ArgumentError unless label == self.name.split('::')[-1].downcase
          find_by_id(i)
        end
      end

      def to_ref
        [self.class.name.split('::')[-1].downcase, id]
      end
    end

    class TaskQueue
      def initialize(taskset_id)
        @key = ['rrrspec', 'taskset', taskset_id.to_s, 'queue'].join(':')
      end

      def enqueue(task)
        RRRSpec::Server.redis.rpush(@key, task.id)
      end

      def reversed_enqueue(task)
        RRRSpec::Server.redis.lpush(@key, task.id)
      end

      def size
        RRRSpec::Server.redis.llen(@key)
      end

      def empty?
        size == 0
      end

      def dequeue
        task_id = RRRSpec::Server.redis.lpop(@key)
        task_id ? Task.find_by_id(task_id) : nil
      end

      def clear
        RRRSpec::Server.redis.del(@key)
      end
    end

    class Taskset < ActiveRecord::Base
      STATUS_RSYNC_WAITING = 'rsync_waiting'
      STATUS_WAITING = 'waiting'
      STATUS_RUNNING = 'running'
      STATUS_SUCCEEDED = 'succeeded'
      STATUS_FAILED = 'failed'
      STATUS_CANCELLED = 'cancelled'

      include JSONConstructor::TasksetJSONConstructor
      include LargeStringAttribute
      include TypeIDReferable
      has_many :worker_logs
      has_many :slaves
      has_many :tasks
      large_string :log

      def self.dispatch
        # TODO
      end

      def self.using
        where(status: [STATUS_RSYNC_WAITING, STATUS_WAITING, STATUS_RUNNING])
      end

      def self.is_running?(rsync_name)
        !users(rsync_name).using.empty?
      end

      def self.full
        includes(
          :tasks => [{:trials => [:task, :slave]}, :taskset],
          :slaves => [:trials],
          :worker_logs => [:taskset]
        )
      end

      def self.users(rsync_name)
        where(rsync_name: rsync_name)
      end

      def queue
        @queue ||= TaskQueue.new(id)
      end

      def start_working
        if status == STATUS_RSYNC_WAITING
          update_attributes(status: STATUS_WAITING)
        end
      end

      def fail
        finish(STATUS_FAILED)
      end

      def cancel
        finish(STATUS_CANCELLED)
      end

      def finished?
        [STATUS_SUCCEEDED, STATUS_FAILED, STATUS_CANCELLED].include?(status)
      end

      def finish(status)
        unless finished?
          update_attributes(status: status, finished_at: Time.zone.now)
          queue.clear
        end
      end

      def try_finish
        return if finished?

        unfinished_tasks = tasks.unfinished.includes(:trials).select do |task|
          !task.try_finish(max_trials)
        end

        if unfinished_tasks.empty?
          finish(tasks.failed.count > 0 ? STATUS_FAILED : STATUS_SUCCEEDED)
        elsif queue.empty?
          requeue_speculative(unfinished_tasks)
        end
      end

      def requeue_speculative(tasks)
        groups = tasks.unfinished.group_by { |task| task.trials.size }
        groups[groups.keys.min].sample.enqueue
      end
    end

    class Task < ActiveRecord::Base
      ONE_DAY_SEC = 24 * 60 * 60
      AVERAGE_ROW_LIMIT = 100
      STATUS_UNFINISHED = nil
      STATUS_PASSED = 'passed'
      STATUS_PENDING = 'pending'
      STATUS_FAILED = 'failed'

      include JSONConstructor::TaskJSONConstructor
      include TypeIDReferable
      belongs_to :taskset
      has_many :trials

      def self.unfinished
        where(status: STATUS_UNFINISHED)
      end

      def self.failed
        where(status: STATUS_FAILED)
      end

      def self.calc_average(taskset_class, spec_sha1)
        times = Trial.joins(task: [:taskset]).where(
          status: [STATUS_PASSED, STATUS_PENDING],
          tasks: {spec_sha1: spec_sha1},
          tasksets: {taskset_class: taskset_class},
        ).order(created_at: :desc).limit(AVERAGE_ROW_LIMIT).pluck(:started_at, :finished_at)
        durations = times.map do |started_at, finished_at|
          finished_at - started_at
        end
        if durations.empty?
          nil
        else
          (durations.sum / durations.size).to_i
        end
      end

      def self.average_cache_key(taskset_class, spec_sha1)
        ['rrrspec', 'average', taskset_class, spec_sha1].join(':')
      end

      def self.update_average(taskset_class, spec_sha1)
        avg = calc_average(taskset_class, spec_sha1)
        if avg
          RRRSpec::Server.redis.setex(average_cache_key(taskset_class, spec_sha1), ONE_DAY_SEC, avg.to_s)
        end
        avg
      end

      def self.average(taskset_class, spec_sha1)
        avg = RRRSpec::Server.redis.get(average_cache_key(taskset_class, spec_sha1))
        if avg
          avg.to_i
        else
          Task.update_average(taskset_class, spec_sha1)
        end
      end

      def enqueue
        TaskQueue.new(taskset_id).enqueue(self)
      end

      def reversed_enqueue
        TaskQueue.new(taskset_id).reversed_enqueue(self)
      end

      def try_finish(max_trials=taskset.max_trials)
        return true if status.present?

        statuses = trials.pluck(:status)
        case
        when statuses.include?(Trial::STATUS_PASSED)
          update_attributes(status: STATUS_PASSED)
          Task.update_average(taskset.taskset_class, spec_sha1)
          true
        when statuses.include?(Trial::STATUS_PENDING)
          update_attributes(status: STATUS_PENDING)
          Task.update_average(taskset.taskset_class, spec_sha1)
          true
        when statuses.include?(nil)
          false
        else
          faileds = statuses.count { |status| [Trial::STATUS_FAILED, Trial::STATUS_ERROR, Trial::STATUS_TIMEOUT].include?(status) }
          if faileds >= max_trials
            update_attributes(status: 'failed')
            true
          else
            reversed_enqueue
            false
          end
        end
      end

      def taskset_ref
        [:taskset, taskset_id]
      end
    end

    class Trial < ActiveRecord::Base
      STATUS_UNFINISHED = nil
      STATUS_PASSED = 'passed'
      STATUS_PENDING = 'pending'
      STATUS_FAILED = 'failed'
      STATUS_ERROR = 'error'
      STATUS_TIMEOUT = 'timeout'

      include JSONConstructor::TrialJSONConstructor
      include LargeStringAttribute
      include TypeIDReferable
      belongs_to :task
      belongs_to :slave
      large_string :stdout
      large_string :stderr

      def finish(trial_status, stdout, stderr, passed_count, pending_count, failed_count)
        update_attributes(
          finished_at: Time.zone.now,
          status: trial_status,
          stdout: stdout,
          stderr: stderr,
          passed: passed_count,
          pending: pending_count,
          failed: failed_count,
        )
        task.try_finish
      end

      def task_ref
        [:task, task_id]
      end

      def slave_ref
        [:slave, slave_id]
      end
    end

    # TODO: Move to Redis
    class Worker
      @@workers = Hash.new

      def self.all
        revoke_outdated
        @@workers.values
      end

      def self.revoke_outdated
        limit = Time.zone.now - OUTDATED_LIMIT_SEC.second
        @@workers.values.each do |worker|
          if worker.updated_at && worker.updated_at < limit
            @@workers.delete(worker.name)
          end
        end
      end

      def self.with_name(name)
        @@workers[name] ||= Worker.new(name)
      end

      attr_reader :name, :updated_at

      def current_taskset_ref
        @current_taskset_ref
      end

      def current_taskset_ref=(taskset_ref)
        @current_taskset_ref = taskset_ref ? taskset_ref : nil
        @updated_at = Time.zone.now
        taskset_ref
      end

      private

      def initialize(name)
        @name = name
        @current_taskset_ref = nil
        @updated_at = nil
      end
    end

    class WorkerLog < ActiveRecord::Base
      include JSONConstructor::WorkerLogJSONConstructor
      include LargeStringAttribute
      include TypeIDReferable
      belongs_to :taskset
      large_string :log

      def finish_rsync
        update_attributes(rsync_finished_at: Time.zone.now)
      end

      def finish_setup
        update_attributes(setup_finished_at: Time.zone.now)
      end

      def finish_rspec
        update_attributes(rspec_finished_at: Time.zone.now)
        log.flush
      end

      def taskset_ref
        [:taskset, taskset_id]
      end
    end

    class Slave < ActiveRecord::Base
      include JSONConstructor::SlaveJSONConstructor
      include TypeIDReferable
      belongs_to :taskset
      has_many :trials

      def finish(status)
        update_attributes(status: status, finished_at: Time.zone.now)
        log.flush
      end

      def taskset_ref
        [:taskset, taskset_id]
      end
    end
  end
end
