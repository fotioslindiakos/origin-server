require 'benchmark'

module Benchmarked
  def bm(key)
    @benchmarks ||= {}
    @benchmarks[key] = Benchmark.realtime do
      yield
    end
  end

  def benchmarks
    @benchmarks.inject({}) do |h,(k,v)|
      h[k] = v.round(4)
      h
    end
  end
end
