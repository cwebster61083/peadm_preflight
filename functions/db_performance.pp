# @summary Check database performance metrics
#
# Validates database I/O performance and disk throughput on PostgreSQL nodes.
# Measures disk write throughput and I/O wait percentage over a 1-second window.
#
# @param psql_targets
#   PostgreSQL target nodes to check
#
# @return [Hash]
#   Hash with performance metrics and validation results
function peadm_preflight::db_performance(
  Optional[Array[String]] $psql_targets = [],
) >> Hash {
  if $psql_targets.size == 0 {
    return({ 'status' => 'skipped', 'reason' => 'no PostgreSQL targets' })
  }

  # Disk write throughput check — 100 MB/s minimum
  out::message('  Checking disk write throughput on PostgreSQL nodes...')
  $db_throughput_min_mbs = 100
  $throughput_check = run_command(
    @(CMD),
      dd if=/dev/zero of=/tmp/peadm_preflight_dd bs=1M count=256 conv=fdatasync 2>&1 | \
      awk '/copied/{for(i=1;i<=NF;i++) if($i~/MB\/s/){printf "%.0f",$(i-1); exit}}'
    |-CMD
    $psql_targets,
    '_catch_errors' => true,
  )

  # Clean up temporary files
  run_command('rm -f /tmp/peadm_preflight_dd', $psql_targets, '_catch_errors' => true)

  $throughput_warnings = $throughput_check.ok_set.results.filter |$r| {
    $raw = $r['stdout'].strip
    $raw =~ /^\d+$/ and Integer($raw, 10) < $db_throughput_min_mbs
  }.map |$r| {
    "${r.target.name}: disk write ${r['stdout'].strip} MB/s (minimum ${db_throughput_min_mbs} MB/s)"
  }

  $throughput_result = {
    'disk_throughput' => $throughput_warnings.size > 0 ? { true => 'warn', default => 'pass' },
    'disk_throughput_warnings' => $throughput_warnings,
  }

  # I/O wait check — 20% maximum
  out::message('  Checking I/O wait percentage on PostgreSQL nodes...')
  $db_iowait_warn_pct = 20
  $iowait_check = run_command(
    @(CMD),
      perl -e 'sub r{open F,"/proc/stat";my @v=(split" ",<F>)[1..8];close F;@v} \
      my @a=r();sleep 1;my @b=r();my $dt=0;$dt+=$b[$_]-$a[$_] for 0..$#a;my $diow=$b[4]-$a[4]; \
      printf "%.1f\n",$dt>0?$diow*100/$dt:0'
    |-CMD
    $psql_targets,
    '_catch_errors' => true,
  )

  $iowait_warnings = $iowait_check.ok_set.results.filter |$r| {
    $raw = $r['stdout'].strip
    $raw =~ /^\d+(\.\d+)?$/ and Float($raw) >= $db_iowait_warn_pct
  }.map |$r| {
    "${r.target.name}: I/O wait ${r['stdout'].strip}% (threshold ${db_iowait_warn_pct}%)"
  }

  $iowait_result = {
    'io_wait' => $iowait_warnings.size > 0 ? { true => 'warn', default => 'pass' },
    'io_wait_warnings' => $iowait_warnings,
  }

  # PostgreSQL service status
  out::message('  Checking pe-postgresql service status...')
  $svc_check = run_command(
    'systemctl is-active pe-postgresql 2>/dev/null || echo inactive',
    $psql_targets,
    '_catch_errors' => true,
  )

  $svc_warnings = $svc_check.ok_set.results.filter |$r| {
    $r['stdout'].strip != 'active'
  }.map |$r| {
    "${r.target.name}: pe-postgresql is ${r['stdout'].strip}"
  }

  $svc_result = {
    'service_status' => $svc_warnings.size > 0 ? { true => 'warn', default => 'pass' },
    'service_warnings' => $svc_warnings,
  }

  $overall_result = {
    'overall' => ($throughput_warnings.size > 0 or $iowait_warnings.size > 0 or $svc_warnings.size > 0) ? { true => 'warn', default => 'pass' },
  }

  $throughput_result + $iowait_result + $svc_result + $overall_result
}
