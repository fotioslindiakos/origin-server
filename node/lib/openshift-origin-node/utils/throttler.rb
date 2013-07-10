require 'cgroups'
require 'queue'

module OpenShift
  module Utils
    class Throttler
      attr_accessor :apps, :utilization, :pids

      def initialize
        @apps = Hash.new do |hash,uuid|
          hash[uuid] = OpenShift::Utils::Cgroups::Attrs.new(uuid)
        end
      end

      def update_apps(uuids)
        pids = get_pids
        get_apps(uuids, pids)
      end

      def throttle(apps)
        boost(apps[:boost])
        restore(apps[:restore])
      end

      def boost(apps)
        app_operation("Boost", apps) do |app|
	  #app.boost_cpu
          {
		#shares: 1024,
		#cfs_period_us: 100000,
		cfs_quota_us:  200000,
		#rt_period_us:  1000000,
		#rt_runtime_us: 	950000 
	  }.each do |k,v|
	    puts "Setting #{k} for #{app.uuid}"
	    app["cpu.#{k}"] = v
	  end
        end
      end

      def restore(apps)
        app_operation("Restore", apps) do |app|
          #app.restore_cpu
          {
		shares: 128,
		cfs_period_us: 100000,
		cfs_quota_us:   30000,
		rt_period_us:  100000,
		rt_runtime_us:      0,
	  }.each do |k,v|
	    app["cpu.#{k}"] = v
	  end
        end
      end

      def current_utilization
        @utilization = OpenShift::Utils::Cgroups::Attrs.new('').process_utilization
      end

      def self.throttle_apps(apps)
        @throttler ||= $throttler ||= (
          puts "Creating new throttler"
          OpenShift::Utils::Throttler.new
        )

        @throttler.update_apps(apps)

        (missing_pids, apps) = @throttler.apps.values.partition{|x| x.pids.empty? }

        missing_pids.each do |app|
          Syslog.info("Missing PIDS: #{app.uuid}")
        end

        (boosted_apps, normal_apps) = apps.partition{|x| x.boosted? }

        long_running = boosted_apps.select{|app| app.running_time > 60 }
        #new_apps     = normal_apps.select{|app| app.running_time < 30 }

        @throttler.throttle(
        #  boost: new_apps,
          restore: long_running
        )
      end

      protected

      # Create Cgroup objects for each UUID
      def get_apps(uuids, pids)
        @apps.keep_if{|k,_| uuids.include?(k) }
        uuids.each do |uuid|
          begin
            @apps[uuid].pids = pids[uuid] || []
          rescue RuntimeError => e
            Syslog.warning(e.message)
          end
        end
      end

      def app_operation(msg, apps)
        OpenShift::Utils::Queue.run(10, quiet: true) do |q|
          apps.each do |app|
	    unless app.is_a? OpenShift::Utils::Cgroups::Attrs
              app = @apps[app]
	    end
            q.enqueue(msg) do
              yield app
            end
          end
        end
      end

      def get_pids
        lines = OpenShift::Utils.oo_spawn("egrep '/openshift/.*$' /proc/*/cgroup | awk -F/ '{print $3,$NF}'")[0].lines.to_a.map(&:split)
        lines.inject({}){|h,line| (pid,uuid) = line; (h[uuid] ||= []) << pid.to_i; h}
      end
    end
  end
end
