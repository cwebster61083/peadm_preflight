# @summary Check database connectivity from PE servers
#
# Validates that PE servers can reach the PostgreSQL database on port 5432.
# Tests connectivity from all PE servers (primary and compilers) to both PostgreSQL nodes.
#
# @param pe_server_targets
#   PE server targets (primary, replica, compilers) that need to reach PostgreSQL
#
# @param primary_postgresql_target
#   Primary PostgreSQL target
#
# @param replica_postgresql_target
#   Replica PostgreSQL target (optional, XL only)
#
# @return [Hash]
#   Hash with connectivity status for each connection path
function peadm_preflight::db_connectivity(
  Optional[Array[String]]     $pe_server_targets           = [],
  Optional[Array[String]]     $primary_postgresql_target   = [],
  Optional[Array[String]]     $replica_postgresql_target   = [],
) >> Hash {
  $primary_psql_status = if ($pe_server_targets.size > 0 and $primary_postgresql_target.size > 0) {
    $check = run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${$primary_postgresql_target[0]}/5432'",
      $pe_server_targets,
      '_catch_errors' => true,
    )
    if $check.ok_set.size > 0 { 'pass' } else { 'fail' }
  } else {
    undef
  }

  $replica_psql_status = if ($pe_server_targets.size > 0 and $replica_postgresql_target.size > 0) {
    $check = run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${$replica_postgresql_target[0]}/5432'",
      $pe_server_targets,
      '_catch_errors' => true,
    )
    if $check.ok_set.size > 0 { 'pass' } else { 'fail' }
  } else {
    undef
  }

  $result_primary = $primary_psql_status ? {
    undef   => {},
    default => { 'primary_postgresql_connectivity' => $primary_psql_status },
  }

  $result_replica = $replica_psql_status ? {
    undef   => {},
    default => { 'replica_postgresql_connectivity' => $replica_psql_status },
  }

  $result_primary + $result_replica
}
