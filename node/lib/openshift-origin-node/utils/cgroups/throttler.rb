#!/usr/bin/env oo-ruby

require 'active_support/core_ext/numeric/time'
require 'openshift-origin-node/utils/cgroups'
require 'openshift-origin-node/utils/cgroups/monitored_gear'
require 'yaml'

module OpenShift
  module Runtime
    module Utils
      class Cgroups
        class Throttler
          ROOT_UUID = ""

          def initialize(*args)
            # Make sure we create a MonitoredGear for the root OpenShift cgroup
            @wanted_uuids = [ROOT_UUID]
            # Keys for information we want from cgroups
            @wanted_keys = %w(usage throttled_time nr_periods cfs_quota_us).map(&:to_sym)
            # Allow us to synchronize destructive operations to @running_apps
            @mutex = Mutex.new

            # Go through any arguments passed to us
            Hash[*args].each do |k,v|
              case k
              when :intervals, :delay
                MonitoredGear.send("#{k}=",v)
              when :uuids
                @wanted_uuids |= [*v]
              end
            end

            # Allow us to lazy initialize MonitoredGears
            @running_apps = Hash.new do |h,k|
              h[k] = MonitoredGear.new(k)
            end

            # Start our collector thread
            start
          end

          # Loop through all lines from grep and contruct a hash
          def parse_usage(info)
            info.lines.map(&:strip).inject(Hash.new{|h,k| h[k] = {}}) do |h,line|
              # Split the output into the file and data
              (file,info) = line.split(':')
              # Create a path out of the filename and extract the uuid
              uuid = File.dirname(file).split('/').last
              # If there was no uuid, then we should use the ROOT_UUID
              if uuid == "openshift"
                uuid = ROOT_UUID
              end
              # Create a key out of the filename
              key = File.basename(file).split('.').last
              # Get the value out of the data
              parts = info.split
              val = parts.last.to_i
              # Some of the files have multiple lines, so we use that as the key instead
              if parts.length == 2
                key = parts.first
              end
              # Save the value
              h[uuid][key.to_sym] = val
              h
            end
          end

          def get_usage
            parse_usage(`grep -H "" /cgroup/all/openshift/{,*/}{cpu.stat,cpuacct.usage,cpu.cfs_quota_us} 2> /dev/null`)
          end

          def start
            Thread.new do
              loop do
                vals = get_usage
                vals = Hash[vals.map{|uuid,hash| [uuid,hash.select{|k,v| @wanted_keys.include?k}]}]

                update(vals)

                sleep MonitoredGear::delay
              end
            end
          end

          # Update our MonitoredGears based on new data
          def update(vals)
            # Synchronize this in case uuids are deleted
            @mutex.synchronize do
              vals.keep_if{|k,v| uuids.include?(k) }
              vals.each do |uuid,data|
                begin
                  @running_apps[uuid].update(data)
                rescue ArgumentError
                  # Sometimes we enter a race condition with app creation/deletion
                  # This will cause the MonitoredGear object to not be created
                  # We can ignore this error and retry it next time
                end
              end
            end
          end

          def root_app
            @running_apps[ROOT_UUID]
          end

          # This combines any uuids of running gears and any uuids we always want
          def uuids
            [@uuids, @wanted_uuids].flatten.uniq
          end

          def user_apps
            @running_apps.select{|k,v| @uuids.include?(k) }
          end

          # Update the list of uuids
          # Synchronize this in case we remove applications in the middle of an update
          def uuids=(new_uuids)
            @mutex.synchronize do
              # Set the uuids of running gears
              @uuids = new_uuids
              # Make sure to use the helper here so we include the wanted_uuids
              missing_apps = @running_apps.keys - uuids
              # Delete any missing gears to free up memory
              @running_apps.delete_if{|k,v| missing_apps.include?(k) }
            end
          end

          def report
            x = @running_apps.inject({}) do |h,(k,v)|
              h[k] = {
                age:         v.age,
                utilization: v.utilization
              }
              h
            end
            x.to_yaml
          end
        end
      end
    end
  end
end
