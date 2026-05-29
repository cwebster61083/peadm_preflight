#!/opt/puppetlabs/puppet/bin/ruby
require 'json'
require 'net/http'
require 'uri'
require 'openssl'

def fetch_status(host, port, timeout = 5)
  http = Net::HTTP.new(host, port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  http.open_timeout = timeout
  http.read_timeout = timeout
  resp = http.get('/status/v1/services')
  raise "HTTP #{resp.code}" unless resp.code == '200'
  resp.body
end

def extract_states(body_json)
  JSON.parse(body_json).each_with_object({}) do |(svc_name, svc_info), memo|
    memo[svc_name] = svc_info.is_a?(Hash) ? svc_info['state'] : svc_info
  end
end

# Standard PE status endpoints. Ports that don't respond are not an error
# in themselves — a compiler legitimately doesn't run console-services or
# orchestrator. Errors are surfaced separately so the plan can decide what
# counts as drift vs expected.
ports = {
  8140 => 'puppetserver',
  8081 => 'puppetdb',
  4433 => 'console-services',
  8143 => 'orchestrator',
}

services = {}
errors = {}

ports.each do |port, label|
  body = fetch_status('localhost', port)
  services.merge!(extract_states(body))
rescue StandardError => e
  errors[port.to_s] = "#{label}: #{e.message}"
end

puts({ 'services' => services, 'errors' => errors }.to_json)
