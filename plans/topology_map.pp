# @summary Generate a Mermaid topology diagram for a PE infrastructure.
#
# Auto-discovers the PE topology via `peadm::get_peadm_config` on the primary,
# then probes each infrastructure node's pxp-agent, puppet.conf, and
# puppetdb.conf to validate configuration alignment. Renders the results as a
# Mermaid flowchart with green edges (aligned) or red-dashed edges (drift).
#
# Requires `puppetlabs/peadm` on the module path.
#
# @param primary_host
#   The hostname or IP of the PE primary server.
plan peadm_preflight::topology_map(
  Peadm::SingleTargetSpec $primary_host,
) {
  $primary_target = peadm::get_targets($primary_host, 1)

  out::message('# Discovering PE topology from primary')
  $config_result = run_task('peadm::get_peadm_config', $primary_target).first.value

  if $config_result['error'] {
    fail_plan("get_peadm_config failed: ${$config_result['error']}")
  }

  $params        = $config_result['params']
  $primary       = $params['primary_host']
  $replica       = $params['replica_host']
  $primary_psql  = $params['primary_postgresql_host']
  $replica_psql  = $params['replica_postgresql_host']
  $pe_comps      = $params['compilers'] ? { undef => [], default => $params['compilers'] }
  $leg_comps     = $params['legacy_compilers'] ? { undef => [], default => $params['legacy_compilers'] }
  $all_compilers = ($pe_comps + $leg_comps).unique

  $replica_targets = $replica ? { undef => [], default => [$replica] }
  $psql_targets    = [$primary_psql, $replica_psql].filter |$v| { $v =~ NotUndef }
  $probe_targets   = ([$primary] + $replica_targets + $all_compilers + $psql_targets).unique

  out::message("# Running configuration probes on ${probe_targets.size} node(s): ${probe_targets.join(', ')}")
  $broker_rs = run_task('peadm_preflight::get_agent_broker',  $probe_targets, '_catch_errors' => true)
  $puppet_rs = run_task('peadm_preflight::get_puppet_conf',   $probe_targets, '_catch_errors' => true)
  $pdb_rs    = run_task('peadm_preflight::get_puppetdb_conf', $probe_targets, '_catch_errors' => true)

  $broker_by = $broker_rs.reduce({}) |$m, $r| { $m + { $r.target.name => $r } }
  $puppet_by = $puppet_rs.reduce({}) |$m, $r| { $m + { $r.target.name => $r } }
  $pdb_by    = $pdb_rs.reduce({})    |$m, $r| { $m + { $r.target.name => $r } }

  # Expected endpoints — any primary/replica is a valid target for HA
  $all_primary_names = ([$primary] + $replica_targets).unique
  $exp_pcp     = $all_primary_names.map |$p| { "wss://${p}:8142/pcp2/" }
  $exp_servers = $all_primary_names
  $exp_pdb     = $all_primary_names.map |$p| { "https://${p}:8081" }

  # Build edges for each compiler
  $edges = $all_compilers.map |$c| {
    $br = $broker_by[$c]
    $pp = $puppet_by[$c]
    $pd = $pdb_by[$c]

    $pcp_uris = $br =~ NotUndef ? {
      true    => $br.ok ? {
        true    => ($br.value['broker_uris'] =~ NotUndef ? {
          true    => $br.value['broker_uris'],
          default => [$br.value['broker_uri']],
        }),
        default => [],
      },
      default => [],
    }

    $servers = $pp =~ NotUndef ? {
      true    => $pp.ok ? {
        true    => [$pp.value['server'], $pp.value['primary_server']].filter |$v| { $v =~ NotUndef },
        default => [],
      },
      default => [],
    }

    $pdb_urls = $pd =~ NotUndef ? {
      true    => $pd.ok ? {
        true    => ($pd.value['server_urls'] =~ NotUndef ? {
          true    => $pd.value['server_urls'],
          default => [],
        }),
        default => [],
      },
      default => [],
    }

    $pcp_valid    = $exp_pcp.any     |$e| { $e in $pcp_uris }
    $server_valid = $exp_servers.any |$e| { $e in $servers }
    $pdb_valid    = $exp_pdb.any     |$e| { $e in $pdb_urls }

    $pcp_edge    = { 'from' => $c, 'kind' => 'pcp',           'valid' => $pcp_valid,    'actual' => $pcp_uris, 'expected' => $exp_pcp }
    $server_edge = { 'from' => $c, 'kind' => 'puppet_server', 'valid' => $server_valid, 'actual' => $servers,  'expected' => $exp_servers }
    $pdb_edge    = { 'from' => $c, 'kind' => 'puppetdb',      'valid' => $pdb_valid,    'actual' => $pdb_urls, 'expected' => $exp_pdb }
    [$pcp_edge, $server_edge, $pdb_edge]
  }.flatten

  # Build node list with roles
  $nodes = $probe_targets.map |$n| {
    $role = $n == $primary ? {
      true    => 'primary',
      default => ($n in $replica_targets) ? {
        true    => 'replica',
        default => ($n in $pe_comps) ? {
          true    => 'pe_compiler',
          default => ($n in $leg_comps) ? {
            true    => 'legacy_compiler',
            default => ($n in $psql_targets) ? {
              true    => 'pe_postgres',
              default => 'unknown',
            },
          },
        },
      },
    }
    $node_entry = { 'name' => $n, 'role' => $role }
    $node_entry
  }

  $model   = { 'nodes' => $nodes, 'edges' => $edges }
  $diagram = peadm_preflight::render_mermaid($model)

  out::message("\n```mermaid\n${diagram}\n```\n")

  return({ 'diagram' => $diagram, 'model' => $model })
}
