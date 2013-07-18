#!/usr/bin/env oo-ruby

require 'active_support/core_ext/numeric/time'
require 'openshift-origin-node/utils/cgroups'
require 'openshift-origin-node/utils/cgroups/benchmarked'

# Provide some helpers for array math
# These will only work on arrays of number values
class Array
  # Get the average value for an array
  def average
    inject(&:+) / length
  end

  # Perform division
  # - If provided with an array, will divide all values
  # - If provided with an integer, will divide all values by that value
  def divide(arr)
    unless arr.is_a?(Array)
      arr = [arr] * length
    end
    map(&:to_f).zip(arr).map{|v| v.first / v.last }
  end

  # Perform multiplication
  # - If provided with an array, will multiply all values
  # - If provided with an integer, will multiply all values by that value
  def mult(arr)
    unless arr.is_a?(Array)
      arr = [arr] * length
    end
    zip(arr).map{|x| x.first * x.last }
  end
end

module OpenShift
  module Runtime
    module Utils
      class Cgroups
        class MonitoredGear < Attrs
          include Benchmarked
          @@delay = 5.seconds

          @@intervals = [10.seconds, 30.seconds]
          @@max = @@intervals.max + (@@delay * 2)

          attr_accessor :thread, :times, :utilization

          def initialize(*args)
            super
            @times = {}
            @utilization = {}
          end

          # Get the current values and remove any expired values
          # Then make sure our intervals are updated
          def update(vals)
            bm(:update) do
              time = Time.now
              @times[time] = vals
              oldest = time - @@max
              @times.delete_if{|k,v| k < oldest }
            end
            bm(:utilization) do
              @utilization = update_utilization
            end
          end

          def oldest
            @times.min.first
          end

          def newest
            @times.max.first
          end

          def age
             (newest - oldest) rescue 0.0
          end

          # Update the elapsed intervals
          def update_utilization
            return if @times.empty?
            cur = newest
            # Go through each interval we want
            @@intervals.inject({}) do |h,i|
              # Make sure we have enough sample points for this dataset
              if age >= i
                # Find any values at or after our cutoff
                vals = @times.select{|k,v| k >= (cur - i)}
                # Calculate the elapsed usage for our values
                h[i] = elapsed_usage(vals.values)
              end
              h
            end
          end

          # Calculate the elapsed usage as a percentage of the max for that time
          # period
          # Doing it this way allows us to calculate the percentage based on the
          # quota and period at the time of each measurement in case it changes
          def elapsed_usage(hashes)
            # These are keys we don't want to include in our calculations
            util_keys = [:cfs_quota_us, :nr_periods]
            # Collect all of the values into a single hash
            values = hashes.inject(Hash.new{|h,k| h[k] = []}){|h,vals| vals.each{|k,v| h[k] << v}; h}
            # Calculate the differences across values
            differences = values.inject({}){|h,(k,v)| h[k] = v.each_cons(2).map { |a,b| b-a }; h}

            # Disregard the first quota, so we can align with the differences
            (quotas = values[:cfs_quota_us]).shift
            periods = differences[:nr_periods]

            # Find the max utils by multiplying the quotas and number of elapsed periods
            max_utils = quotas.mult(periods)

            differences.inject({}) do |h,(k,vals)|
              unless util_keys.include?(k) || vals.empty?
                # Calculate the values as a percentage of the max utilization for a period
                percentage = vals.divide(max_utils).mult(100)
                per_period = vals.divide(periods)
                {
                  nil          => vals.average,
                  "per_period" => per_period.average.round(3),
                  "percent"    => percentage.average.round(3),
                }.each do |k2,v|
                  key = [k,k2].compact.join('_').to_sym
                  h[key] = v
                end
              end
              h
            end
          end

          class << self
            def intervals=(intervals)
              @@intervals = intervals
              @@max = @@intervals.max + (@@delay * 2)
            end

            def delay=(delay)
              @@delay = delay
              @@max = @@intervals.max + (@@delay * 2)
            end

            def delay
              @@delay
            end
          end
        end
      end
    end
  end
end
