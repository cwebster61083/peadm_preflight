#!/opt/puppetlabs/puppet/bin/ruby
require 'json'

# puppet.conf is INI-shaped. We parse it minimally: only [main], [agent], [server]
# matter for topology. We carry duplicate keys by section, last-write-wins per
# Puppet's own resolution order (main < agent for an agent runtime).
def parse_ini(text)
  sections = Hash.new { |h, k| h[k] = {} }
  current = 'main'
  text.each_line do |raw|
    line = raw.strip
    next if line.empty? || line.start_with?('#', ';')

    if (m = line.match(%r{\A\[([^\]]+)\]\z}))
      current = m[1].strip
      next
    end

    if (m = line.match(%r{\A([A-Za-z0-9_]+)\s*=\s*(.*)\z}))
      sections[current][m[1]] = m[2].strip
    end
  end
  sections
end

text     = File.read('/etc/puppetlabs/puppet/puppet.conf')
sections = parse_ini(text)

# Agent runtime resolution: [agent] overrides [main].
# For 'server' the historical key is 'server'; PE 2021+ also accepts
# 'server_list' and 'primary_server'.
merged = sections['main'].merge(sections['agent'] || {})

result = {
  'certname'       => merged['certname'],
  'server'         => merged['server'],
  'server_list'    => merged['server_list'],
  'primary_server' => merged['primary_server'],
  'environment'    => merged['environment'],
  'sections'       => sections,
}

puts result.to_json
