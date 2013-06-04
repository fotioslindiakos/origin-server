#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'uri'

# Retrieves the JSON from the server and grabs the desired values
def get_json(url, keys)
  raw = `curl -kL #{url} 2> /dev/null`
  json = JSON.parse(raw)['data']
  json = yield(json) if block_given?
  json.map{|x| x.values_at(*keys) }
end

# Parse the GIT url into a friendly format
def parse_git(url)
  uri = URI.parse(url).path
  parts = uri.sub(/\.git$/,'').split('/').delete_if{|x| x.empty? }
  parts.shift if parts.first == 'openshift'
  parts.join('/')
end

# Parse the cartridge string into something usable
def parse_carts(carts)
  # Some of the carts have an escaped JSON type hash
  carts = (if carts =~ /quot/
    JSON.parse(carts.gsub(/&quot;/,'"')).map{|x| x['name'] }
  else
    carts.split(',')
  end).map(&:strip)

  # Some of the carts specify a * in the name or have multiple matches.
  # Try to intelligently pick one to use
  carts.map do |x|
    matching = @cartridges.grep(%r/#{x}/)
    if matching.length > 1
      matching = @cartridges.grep(%r/#{x.sub(/\*/,'\d')}/).first
    end  
    matching
  end
end

# Get the cartridges for matching against
@cartridges = get_json('https://openshift.redhat.com/broker/rest/cartridges.json', %w(name)).flatten
# Get the quickstarts
quickstarts = get_json('https://www.openshift.com/api/v1/quickstarts.json', %w(initial_git_url cartridges)) do |x| 
  # Coerce the object into a array with just the quickstart objects
  x.map{|y| y['quickstart'] }
end

# Some quickstarts do not specify a GIT url, so no point in testing
quickstarts.delete_if{|x| x.first.nil? }

# Clean up the URL and cartridges
quickstarts.map! do |x|
  [parse_git(x.first), parse_carts(x.last).flatten.join(' ')]
end

# Get the lengths of the URL and carts for pretty printing
lengths = quickstarts.map{|x| x.map(&:length) }
@max_lens = lengths.first.each_with_index.map{|_,i| lengths.map{|x| x[i] }.max }

# Split up the official and partner quickstarts into different example groups
keys = %w(official partner)
qs = quickstarts.partition{|x| !x.first.include?('/') }.map{|x| x.sort }
hash = Hash[keys.zip(qs)]

# Print the groups for use in cucumber
hash.each do |key,group|
  puts
  puts "  @#{key}"
  puts "  Examples:"
  group.unshift(%w(qs type))
  lines = group.map{|x| x.each_with_index.map{|y,i| y.ljust(@max_lens[i])} }.map{|y| "    | %s |" % y.join(' | ')}
  puts lines
end
