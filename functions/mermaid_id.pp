# @summary Convert a certname into a Mermaid-safe node identifier.
function peadm_preflight::mermaid_id(String $name) >> String {
  regsubst($name, '[^A-Za-z0-9]', '_', 'G')
}
