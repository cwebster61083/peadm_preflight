# @summary Render a PE topology model as a Mermaid flowchart string.
#
# Model shape:
#   {
#     'nodes' => [ { 'name' => String, 'role' => String }, ... ],
#     'edges' => [ { 'from' => String, 'kind' => String,
#                    'valid' => Boolean, 'actual' => Array, 'expected' => Array }, ... ],
#   }
#
# Returns a `flowchart LR` block with primary/compiler/db node classes and
# linkStyle entries colouring each edge green (valid) or red-dashed (drift).
function peadm_preflight::render_mermaid(Hash $model) >> String {
  $node_lines = $model['nodes'].map |$n| {
    $id    = peadm_preflight::mermaid_id($n['name'])
    $open  = $n['role'] == 'primary' ? {
      true    => '[[',
      default => $n['role'] == 'pe_postgres' ? {
        true    => '[(',
        default => '[',
      },
    }
    $close = $n['role'] == 'primary' ? {
      true    => ']]',
      default => $n['role'] == 'pe_postgres' ? {
        true    => ')]',
        default => ']',
      },
    }
    $class = $n['role'] == 'primary' ? {
      true    => 'primary',
      default => $n['role'] == 'pe_postgres' ? {
        true    => 'db',
        default => $n['role'] == 'legacy_compiler' ? {
          true    => 'legacy',
          default => $n['role'] == 'replica' ? {
            true    => 'replica',
            default => 'compiler',
          },
        },
      },
    }
    "  ${id}${open}\"${n['name']}<br/>(${n['role']})\"${close}:::${class}"
  }.join("\n")

  $edge_acc = $model['edges'].reduce({ 'lines' => [], 'styles' => [], 'i' => 0 }) |$acc, $e| {
    $i       = $acc['i']
    $from_id = peadm_preflight::mermaid_id($e['from'])
    $primary = $e['expected'][0]
    $to_id   = peadm_preflight::mermaid_id($primary)

    $actual = $e['actual'].empty ? { true => '(none)', default => $e['actual'][0] }
    $arrow  = $e['valid'] ? { true => '-->', default => '-.->' }
    $colour = $e['valid'] ? { true => '#198754', default => '#dc3545' }

    $line    = "  ${from_id} ${arrow}|\"${e['kind']}: ${actual}\"| ${to_id}"
    $style   = "  linkStyle ${i} stroke:${colour},stroke-width:2px"
    $next    = { 'lines' => $acc['lines'] + [$line], 'styles' => $acc['styles'] + [$style], 'i' => $i + 1 }
    $next
  }

  $edge_block  = $edge_acc['lines'].join("\n")
  $style_block = $edge_acc['styles'].join("\n")

  $classdefs = @(DEFS)
      classDef primary  fill:#cfe2ff,stroke:#0d6efd,stroke-width:2px
      classDef replica  fill:#d8d5ff,stroke:#3d2bab,stroke-width:2px
      classDef compiler fill:#e2e3e5,stroke:#6c757d
      classDef legacy   fill:#fff3cd,stroke:#ffc107
      classDef db       fill:#d1e7dd,stroke:#198754
    | DEFS

  "flowchart LR\n${node_lines}\n${edge_block}\n${style_block}\n${classdefs}"
}
