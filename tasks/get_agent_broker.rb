#!/opt/puppetlabs/puppet/bin/ruby
require 'json'

conf_data = File.read('/etc/puppetlabs/pxp-agent/pxp-agent.conf')
conf_json = JSON.parse(conf_data)

broker_uris = Array(conf_json['broker-ws-uris'])

result = {
  'broker_uris' => broker_uris,
  'broker_uri'  => broker_uris.first,
}

puts result.to_json
