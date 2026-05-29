# @summary Render a PE topology model as a Mermaid flowchart string.
#
# Model shape:
#   {
#     'nodes' => [ { 'name' => String, 'role' => String,
#                    'services' => Hash, 'errors' => Hash }, ... ],
#     'edges' => [ { 'from' => String, 'kind' => String,
#                    'valid' => Boolean, 'actual' => Array, 'expected' => Array }, ... ],
#   }
#
# Returns a `flowchart TB` block with three subgraphs (Compilers / Primary Tier /
# PostgreSQL) arranged top-to-bottom, matching the standard PE reference architecture.
# Edges carry TCP port labels and are coloured green (valid) or red-dashed (drift).
# Node labels show only the short hostname (first FQDN component) for readability.
# When a node carries a non-empty `services` hash, services whose state is not
# `running` are surfaced as `DEGRADED: svc=state` in the node label.
function peadm_preflight::render_mermaid(Hash $model) >> String {
  $nodes = $model['nodes']
  $edges = $model['edges']

  # ── Group nodes by role ────────────────────────────────────────────────────
  $comp_nodes = $nodes.filter |$n| { ($n['role'] in ['pe_compiler', 'legacy_compiler']) }
  $prim_nodes = $nodes.filter |$n| { $n['role'] == 'primary' }
  $repl_nodes = $nodes.filter |$n| { $n['role'] == 'replica' }
  $psql_nodes = $nodes.filter |$n| { $n['role'] == 'pe_postgres' }

  # ── Node declaration lines (short hostname as label) ───────────────────────
  $comp_decls = $comp_nodes.map |$n| {
    $id  = peadm_preflight::mermaid_id($n['name'])
    $lbl = regsubst($n['name'], '^([^.]+)\..*$', '\1')
    $cls = ($n['role'] == 'legacy_compiler') ? { true => 'legacy', default => 'compiler' }
    $services = $n['services']
    if $services and ! $services.empty {
      $degraded = $services.filter |$k, $v| { $v != 'running' }
      if $degraded.empty {
        $health_line = ''
      } else {
        $parts = $degraded.map |$k, $v| { "${k}=${v}" }
        $health_line = "<br/>DEGRADED: ${parts.join(', ')}"
      }
    } else {
      $health_line = ''
    }
    "    ${id}[\"${lbl}${health_line}\"]:::${cls}"
  }

  $prim_decls = $prim_nodes.map |$n| {
    $id  = peadm_preflight::mermaid_id($n['name'])
    $lbl = regsubst($n['name'], '^([^.]+)\..*$', '\1')
    $services = $n['services']
    if $services and ! $services.empty {
      $degraded = $services.filter |$k, $v| { $v != 'running' }
      if $degraded.empty {
        $health_line = ''
      } else {
        $parts = $degraded.map |$k, $v| { "${k}=${v}" }
        $health_line = "<br/>DEGRADED: ${parts.join(', ')}"
      }
    } else {
      $health_line = ''
    }
    "    ${id}[[\"${lbl}${health_line}\"]]:::primary"
  }

  $repl_decls = $repl_nodes.map |$n| {
    $id  = peadm_preflight::mermaid_id($n['name'])
    $lbl = regsubst($n['name'], '^([^.]+)\..*$', '\1')
    $services = $n['services']
    if $services and ! $services.empty {
      $degraded = $services.filter |$k, $v| { $v != 'running' }
      if $degraded.empty {
        $health_line = ''
      } else {
        $parts = $degraded.map |$k, $v| { "${k}=${v}" }
        $health_line = "<br/>DEGRADED: ${parts.join(', ')}"
      }
    } else {
      $health_line = ''
    }
    "    ${id}[\"${lbl}${health_line}\"]:::replica"
  }

  $psql_decls = $psql_nodes.map |$n| {
    $id  = peadm_preflight::mermaid_id($n['name'])
    $lbl = regsubst($n['name'], '^([^.]+)\..*$', '\1')
    $services = $n['services']
    if $services and ! $services.empty {
      $degraded = $services.filter |$k, $v| { $v != 'running' }
      if $degraded.empty {
        $health_line = ''
      } else {
        $parts = $degraded.map |$k, $v| { "${k}=${v}" }
        $health_line = "<br/>DEGRADED: ${parts.join(', ')}"
      }
    } else {
      $health_line = ''
    }
    "    ${id}[(\"${lbl}${health_line}\")]:::db"
  }

  # ── Subgraph blocks ────────────────────────────────────────────────────────
  # Compilers stacked top; primary + replica side-by-side in middle; psql at bottom
  $comp_block = $comp_nodes.size > 0 ? {
    true    => "  subgraph COMPILERS[\"Compilers\"]\n    direction TB\n${comp_decls.join("\n")}\n  end",
    default => '',
  }

  $prim_tier_decls = $prim_decls + $repl_decls
  $prim_block = $prim_tier_decls.size > 0 ? {
    true    => "  subgraph PRIMARY_TIER[\"Primary Tier\"]\n    direction LR\n${prim_tier_decls.join("\n")}\n  end",
    default => '',
  }

  $psql_block = $psql_nodes.size > 0 ? {
    true    => "  subgraph PSQL_TIER[\"PostgreSQL\"]\n    direction LR\n${psql_decls.join("\n")}\n  end",
    default => '',
  }

  $subgraph_block = [$comp_block, $prim_block, $psql_block].filter |$b| { $b != '' }.join("\n\n")

  # ── Compiler/replica → primary edges (port-labelled, coloured by validity) ─
  # Strip URL scheme and port/path from expected[0] to recover the bare certname
  # e.g. "wss://host:8142/pcp2/" → "host", "https://host:8081" → "host", "host" → "host"
  $compiler_edge_data = $edges.map |$e| {
    $from_id = peadm_preflight::mermaid_id($e['from'])
    $to_host = regsubst(regsubst($e['expected'][0], '^[a-z]+://', ''), '[:/?].*$', '')
    $to_id   = peadm_preflight::mermaid_id($to_host)
    $lbl     = $e['kind'] == 'pcp' ? {
      true    => 'TCP-8142',
      default => $e['kind'] == 'puppet_server' ? {
        true    => 'TCP-8140',
        default => 'TCP-8081',
      },
    }
    $arrow = $e['valid'] ? { true => '-->', default => '-.->' }
    $col   = $e['valid'] ? { true => '#198754', default => '#dc3545' }
    $entry = { 'line' => "  ${from_id} ${arrow}|\"${lbl}\"| ${to_id}", 'colour' => $col }
    $entry
  }

  # ── Primary/replica → PostgreSQL structural edges ──────────────────────────
  $psql_edge_data = ($prim_nodes + $repl_nodes).reduce([]) |$memo, $pn| {
    $memo + $psql_nodes.map |$dbnode| {
      $from_id = peadm_preflight::mermaid_id($pn['name'])
      $to_id   = peadm_preflight::mermaid_id($dbnode['name'])
      $psql_entry = { 'line' => "  ${from_id} -->|\"TCP-5432\"| ${to_id}", 'colour' => '#0d6efd' }
      $psql_entry
    }
  }

  $all_edge_data = $compiler_edge_data + $psql_edge_data
  $edge_lines  = $all_edge_data.map |$e| { $e['line'] }
  $style_lines = $all_edge_data.map |$i, $e| {
    "  linkStyle ${i} stroke:${$e['colour']},stroke-width:2px"
  }

  # ── Class definitions ──────────────────────────────────────────────────────
  $classdefs = @(DEFS)
      classDef primary  fill:#cfe2ff,stroke:#0d6efd,stroke-width:2px
      classDef replica  fill:#d8d5ff,stroke:#3d2bab,stroke-width:2px
      classDef compiler fill:#e2e3e5,stroke:#6c757d
      classDef legacy   fill:#fff3cd,stroke:#ffc107
      classDef db       fill:#d1e7dd,stroke:#198754
    | DEFS

  $all_parts = [$subgraph_block, $edge_lines.join("\n"), $style_lines.join("\n"), $classdefs].filter |$p| { $p != '' }
  "flowchart TB\n${all_parts.join("\n")}"
}
