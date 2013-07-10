module OpenShift
  module Utils
    class Queue
      attr_accessor :threads, :size
      attr_accessor :max, :skip_tick, :skip_elapsed, :quiet

      def initialize(max = 5, *args)
        @max = max
        @threads = []
        Hash[*args].each do |k,v|
          send("#{k}=",v)
        end
      end

      def enqueue(cmd = "", &block)
        if threads.length >= max
          Process.waitpid2(threads.slice!(0))
        end
        tick(cmd) unless skip_tick or quiet
        threads << fork do
          yield
        end
      end

      def wait
        threads.each do |cpid|
          Process.waitpid2(cpid)
        end
      end

      def self.run(*args)
        stime = Time.now
        queue = Queue.new(*args)
        yield queue
        queue.wait
        elapsed = (Time.now - stime).to_f
        puts "Time Elapsed (s): #{elapsed}" unless queue.skip_elapsed or queue.quiet
      end

      protected
      def tick(cmd)
        @iter ||= 0
        @iter += 1
        puts "#{cmd}: #{@iter}%s" % [size.nil? ? '' : " of #{size}"]
      end
    end
  end
end
