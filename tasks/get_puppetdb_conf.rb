#!/opt/puppetlabs/puppet/bin/ruby
require 'json'

# puppetdb.conf has a single [main] section in practice; we only care about
# server_urls. Missing file is a valid state for some PE roles (e.g. external
# postgres nodes) so we surface that without erroring.
conf_path = '/etc/puppetlabs/puppet/puppetdb.conf'

result = {
  'present'     => File.exist?(conf_path),
  'server_urls' => [],
}

if result['present']
  current = nil
  File.read(conf_path).each_line do |raw|
    line = raw.strip
    next if line.empty? || line.start_with?('#', ';')
    if (m = line.match(%r{\A\[([^\]]+)\]\z}))
      current = m[1].strip
      next
    end
    if current == 'main' && (m = line.match(%r{\Aserver_urls\s*=\s*(.*)\z}))
      result['server_urls'] = m[1].split(',').map(&:strip).reject(&:empty?)
    end
  end
end

puts result.to_json
