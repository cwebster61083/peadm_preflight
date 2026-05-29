# @summary Perform preflight checks for a PE cluster before install or upgrade
#
# Validates that the target infrastructure meets requirements before running peadm::install or
# peadm::upgrade. Checks include Bolt version support, PE version support, architecture validity,
# node connectivity, OS platform consistency, hostname/certname alignment, and pxp-agent
# connectivity from compilers to the primary on port 8142. Also validates disk space, memory
# availability, service health, and database performance metrics.
#
# @param primary_host
#   The hostname and certname of the primary Puppet server
#
# @param replica_host
#   The hostname and certname of the replica Puppet server
#
# @param compiler_hosts
#   The hostnames and certnames of any compiler nodes
#
# @param primary_postgresql_host
#   The hostname and certname of the primary PE-PostgreSQL server (XL only)
#
# @param replica_postgresql_host
#   The hostname and certname of the replica PE-PostgreSQL server (XL only)
#
# @param version
#   The target PE version to install or upgrade to. When provided, the version
#   is validated against the set of supported PE versions.
#
# @param token_file
#   Path to a PE RBAC token file. When compiler_hosts are provided, the token
#   is validated against the primary to confirm API access.
#
# @param pe_admin_password
#   Password for the PE admin RBAC user. When provided alongside compiler_hosts,
#   a token will be generated at runtime via peadm::rbac_token instead of
#   requiring a pre-existing token_file.
#
# @param token_lifetime
#   Lifetime for the generated RBAC token. Format <integer>[smhdy]. Defaults to 1h.
#
# @param permit_unsafe_versions
#   When true, suppresses the error raised for PE versions not in the known supported list.
#
# @param html_report_file
#   Path to write an HTML preflight report to. Optional.
plan peadm_preflight::check(
  # Standard
  Optional[String] $primary_host             = undef,
  Optional[String] $replica_host             = undef,

  # Large
  Optional[String] $compiler_hosts           = undef,

  # Extra Large
  Optional[String] $primary_postgresql_host  = undef,
  Optional[String] $replica_postgresql_host  = undef,

  # Common
  Optional[String] $version                  = undef,
  Optional[String] $token_file               = undef,
  Optional[String] $pe_admin_password        = undef,
  String           $token_lifetime           = '1h',
  Boolean          $permit_unsafe_versions   = false,
  Optional[String] $html_report_file         = undef,
  TargetSpec       $targets                  = 'all',
) {
  out::message('# PEADM Preflight Checks')
  out::message('# Validating infrastructure before deployment')

  # Convert inputs into targets
  $primary_target            = $primary_host ? { undef => [], default => [$primary_host] }
  $replica_target            = $replica_host ? { undef => [], default => [$replica_host] }
  $primary_postgresql_target = $primary_postgresql_host ? { undef => [], default => [$primary_postgresql_host] }
  $replica_postgresql_target = $replica_postgresql_host ? { undef => [], default => [$replica_postgresql_host] }
  $compiler_target           = $compiler_hosts ? { undef => [], default => split($compiler_hosts, ',') }

  $all_targets = [
    $primary_target,
    $replica_target,
    $primary_postgresql_target,
    $replica_postgresql_target,
    $compiler_target,
  ].filter |$t| { $t.size > 0 }.flatten

  $all_postgresql_targets = ($primary_postgresql_target + $replica_postgresql_target).unique

  $ts_start = Timestamp()

  out::message("# Checking connectivity to ${all_targets.size} target(s)")
  $ts_connectivity = Timestamp()
  $connectivity_check = wait_until_available($all_targets, wait_time => 60, retry_interval => 5)
  out::message("✓ All ${all_targets.size} target(s) are reachable")

  # ── PXP-agent connectivity ─────────────────────────────────────────────────
  $ts_pxp = Timestamp()
  # Check that compilers can reach the primary orchestrator on port 8142
  if $compiler_target.size > 0 {
    out::message('# Checking pxp-agent connectivity from compilers to primary (port 8142)')
    $pxp_failures = run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/8142'",
      $compiler_target,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:8142" }
  } else {
    $pxp_failures = []
  }

  if $pxp_failures.size > 0 {
    fail_plan("Compilers cannot reach ${primary_host}:8142 (orchestrator/PXP broker). Failed: ${pxp_failures.join(', ')}")
  }

  # ── Firewall checks ────────────────────────────────────────────────────────
  # Ports per https://help.puppet.com/pe/2023.8/topics/firewall_postgres.htm
  $ts_firewall = Timestamp()
  out::message('# Checking firewall rules (PE ports on primary)')

  $firewall_infra_targets = ($replica_target + $compiler_target).unique

  # 443 — HTTPS console access / Code Manager git fetch
  $fw_443_failures = $firewall_infra_targets.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/443'",
      $firewall_infra_targets,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:443" },
    default => [],
  }

  # 4433 — Classifier / console services API
  $fw_4433_failures = $firewall_infra_targets.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/4433'",
      $firewall_infra_targets,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:4433" },
    default => [],
  }

  # 8081 — PuppetDB
  $fw_8081_failures = $firewall_infra_targets.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/8081'",
      $firewall_infra_targets,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:8081" },
    default => [],
  }

  # 8140 — Puppet Server (agents, certificates, status)
  $fw_8140_failures = $firewall_infra_targets.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/8140'",
      $firewall_infra_targets,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:8140" },
    default => [],
  }

  # 8143 — Orchestrator / PCP broker
  $fw_8143_failures = $firewall_infra_targets.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/8143'",
      $firewall_infra_targets,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:8143" },
    default => [],
  }

  # 8170 — Code Manager (deploy environments, webhooks, API)
  $fw_8170_failures = $firewall_infra_targets.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${primary_host}/8170'",
      $firewall_infra_targets,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${primary_host}:8170" },
    default => [],
  }

  # 5432 — PE-PostgreSQL (primary → standalone psql node; compilers → psql node)
  $fw_5432_failures = $primary_postgresql_target.size > 0 ? {
    true => run_command(
      "timeout 5 bash -c 'echo >/dev/tcp/${$primary_postgresql_target[0]}/5432'",
      $primary_target,
      '_catch_errors' => true,
    ).error_set.targets.map |$t| { "${t.name} -> ${$primary_postgresql_target[0]}:5432" },
    default => [],
  }

  $all_fw_failures = $fw_443_failures + $fw_4433_failures + $fw_8081_failures
    + $fw_8140_failures + $fw_8143_failures + $fw_8170_failures + $fw_5432_failures
  if $all_fw_failures.size > 0 {
    out::message("WARNING: Firewall blocking required PE ports:\n  ${all_fw_failures.join("\n  ")}")
  }

  # ── Database connectivity ──────────────────────────────────────────────────
  $ts_db = Timestamp()
  out::message('# Validating database connectivity')
  $db_connectivity = peadm_preflight::db_connectivity($all_targets)
  out::message("✓ Database connectivity validated")

  # ── Database performance ───────────────────────────────────────────────────
  out::message('# Validating database performance')
  $db_performance = peadm_preflight::db_performance($primary_postgresql_target)
  out::message("✓ Database performance metrics collected")

  # ── Disk space check ───────────────────────────────────────────────────────
  $ts_disk = Timestamp()
  out::message('# Checking disk space')
  $disk_min_gb_primary    = 100
  $disk_min_gb_postgresql = 100
  $disk_min_gb_infra      = 50

  $disk_results = run_command(
    "df -BG --output=avail /opt 2>/dev/null | tail -1 | tr -dc '0-9' || df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'",
    $all_targets,
    '_catch_errors' => true,
  )

  $disk_warnings = $disk_results.ok_set.results.filter |$r| {
    $raw = $r['stdout'].strip
    $min = $r.target.name in $primary_target ? {
      true    => $disk_min_gb_primary,
      default => $r.target.name in $all_postgresql_targets ? {
        true    => $disk_min_gb_postgresql,
        default => $disk_min_gb_infra,
      },
    }
    $raw =~ /^\d+$/ and Integer($raw, 10) < $min
  }.map |$r| {
    $avail_gb = Integer($r['stdout'].strip, 10)
    $min = $r.target.name in $primary_target ? {
      true    => $disk_min_gb_primary,
      default => $r.target.name in $all_postgresql_targets ? {
        true    => $disk_min_gb_postgresql,
        default => $disk_min_gb_infra,
      },
    }
    "${r.target.name}: ${avail_gb} GB available (minimum ${min} GB)"
  }

  if $disk_warnings.size > 0 {
    out::message("WARNING: Insufficient disk space on:\n  ${disk_warnings.join("\n  ")}")
  }

  # ── Memory pressure check ──────────────────────────────────────────────────
  $ts_mem = Timestamp()
  out::message('# Checking memory pressure')
  $mem_min_mb_primary = 8192
  $mem_min_mb_infra   = 4096

  $mem_results = run_command(
    "awk '/^MemAvailable/ {print int($2/1024)}' /proc/meminfo",
    $all_targets,
    '_catch_errors' => true,
  )

  $mem_warnings = $mem_results.ok_set.results.filter |$r| {
    $raw = $r['stdout'].strip
    $min = $r.target.name in $primary_target ? { true => $mem_min_mb_primary, default => $mem_min_mb_infra }
    $raw =~ /^\d+$/ and Integer($raw, 10) < $min
  }.map |$r| {
    $avail_mb = Integer($r['stdout'].strip, 10)
    $min = $r.target.name in $primary_target ? { true => $mem_min_mb_primary, default => $mem_min_mb_infra }
    "${r.target.name}: ${avail_mb} MB available (minimum ${min} MB)"
  }

  if $mem_warnings.size > 0 {
    out::message("WARNING: Low available memory on:\n  ${mem_warnings.join("\n  ")}")
  }

  # ── Service health check ───────────────────────────────────────────────────
  $ts_svc = Timestamp()
  out::message('# Checking PE service health')
  $svc_status_result = run_command(
    '/opt/puppetlabs/bin/puppet infra status 2>&1',
    $primary_target,
    '_catch_errors' => true,
  )

  $svc_failures = $svc_status_result.ok_set.results.reduce([]) |$memo, $r| {
    $bad_lines = $r['stdout'].split("\n").filter |$l| {
      $l =~ /(?i)(stopped|failed|error|not running)/
    }.map |$l| { "${r.target.name}: ${l.strip}" }
    $bad_lines.size > 0 ? { true => $memo + $bad_lines, default => $memo }
  }

  $pxp_svc_warnings = $compiler_target.size > 0 ? {
    true => run_command(
      "systemctl is-active pxp-agent 2>/dev/null || echo 'inactive'",
      $compiler_target,
      '_catch_errors' => true,
    ).ok_set.results.filter |$r| {
      $r['stdout'].strip != 'active'
    }.map |$r| { "${r.target.name}: pxp-agent is ${r['stdout'].strip}" },
    default => [],
  }

  $all_svc_issues = $svc_failures + $pxp_svc_warnings
  if $all_svc_issues.size > 0 {
    out::message("WARNING: PE service issues detected:\n  ${all_svc_issues.join("\n  ")}")
  }

  # ── Per-node service detail collection ────────────────────────────────────
  out::message('# Collecting per-node PE service status')
  $ts_svc_detail = Timestamp()
  $svc_detail_results = run_command(
    @(CMD/L),
      systemctl list-units --all --no-pager --plain --no-legend --type=service 2>/dev/null | \
      grep -E '^(pe-|pxp-)' | \
      awk '{printf "%s %s\n", $1, $3}'
      |-CMD
    $all_targets,
    '_catch_errors' => true,
  )

  # ── Log error check ────────────────────────────────────────────────────────
  $ts_logs = Timestamp()
  out::message('# Checking PE service logs for recent errors')

  $primary_log_cmd = run_command(
    @(CMD/L),
      for log in puppetserver/puppetserver puppetdb/puppetdb console-services/console-services orchestration-services/orchestration-services; do \
        errs=$(tail -500 /var/log/puppetlabs/$log.log 2>/dev/null | grep "ERROR\|FATAL"); \
        if [ -n "$errs" ]; then \
          count=$(echo "$errs" | wc -l | tr -d ' '); \
          echo "$log: $count recent error(s)"; \
          echo "$errs" | tail -3 | sed 's/^/  >> /'; \
        fi; \
      done; true
      |-CMD
    $primary_target,
    '_catch_errors' => true,
  )
  $primary_log_warnings = $primary_log_cmd.ok_set.results.filter |$r| {
    $r['stdout'].strip != ''
  }.map |$r| {
    $r['stdout'].strip.split("\n").map |$l| {
      $l =~ /^  >> / ? { true => $l, default => "${r.target.name}: ${l}" }
    }
  }.flatten

  $compiler_log_cmd = $compiler_target.size > 0 ? {
    true    => run_command(
      @(CMD/L),
        errs=$(tail -500 /var/log/puppetlabs/pxp-agent/pxp-agent.log 2>/dev/null | grep "ERROR\|FATAL"); \
        if [ -n "$errs" ]; then \
          count=$(echo "$errs" | wc -l | tr -d ' '); \
          echo "pxp-agent: $count recent error(s)"; \
          echo "$errs" | tail -3 | sed 's/^/  >> /'; \
        fi; true
        |-CMD
      $compiler_target,
      '_catch_errors' => true,
    ),
    default => undef,
  }
  $compiler_log_raw = $compiler_log_cmd =~ NotUndef ? {
    true    => $compiler_log_cmd.ok_set.results,
    default => [],
  }
  $compiler_log_warnings = $compiler_log_raw.filter |$r| {
    $r['stdout'].strip != ''
  }.map |$r| {
    $r['stdout'].strip.split("\n").map |$l| {
      $l =~ /^  >> / ? { true => $l, default => "${r.target.name}: ${l}" }
    }
  }.flatten

  # ── PostgreSQL node log check ─────────────────────────────────────────────
  $postgresql_log_cmd = $all_postgresql_targets.size > 0 ? {
    true    => run_command(
      @(CMD/L),
        for logf in /var/log/puppetlabs/postgresql/*.log; do \
          [ -f "$logf" ] || continue; \
          errs=$(tail -500 "$logf" 2>/dev/null | grep "ERROR\|FATAL"); \
          if [ -n "$errs" ]; then \
            logname=$(basename "$logf" .log); \
            count=$(echo "$errs" | wc -l | tr -d ' '); \
            echo "postgresql/$logname: $count recent error(s)"; \
            echo "$errs" | tail -3 | sed 's/^/  >> /'; \
          fi; \
        done; true
        |-CMD
      $all_postgresql_targets,
      '_catch_errors' => true,
    ),
    default => undef,
  }
  $postgresql_log_raw = $postgresql_log_cmd =~ NotUndef ? {
    true    => $postgresql_log_cmd.ok_set.results,
    default => [],
  }
  $postgresql_log_warnings = $postgresql_log_raw.filter |$r| {
    $r['stdout'].strip != ''
  }.map |$r| {
    $r['stdout'].strip.split("\n").map |$l| {
      $l =~ /^  >> / ? { true => $l, default => "${r.target.name}: ${l}" }
    }
  }.flatten

  $all_log_warnings = $primary_log_warnings + $compiler_log_warnings + $postgresql_log_warnings
  if $all_log_warnings.size > 0 {
    out::message("WARNING: ERROR/FATAL entries found in PE logs:\n  ${all_log_warnings.join("\n  ")}")
  }

  # ── Broker & configuration drift check ────────────────────────────────────
  $ts_broker             = Timestamp()
  $broker_check_targets  = ($compiler_target + $replica_target).unique
  if $broker_check_targets.size > 0 {
    out::message('# Checking pxp-agent broker and server configuration')
  }

  $broker_task_raw = $compiler_target.size > 0 ? {
    true    => run_task('peadm_preflight::get_agent_broker', $compiler_target, '_catch_errors' => true),
    default => undef,
  }
  $puppet_conf_raw = $broker_check_targets.size > 0 ? {
    true    => run_task('peadm_preflight::get_puppet_conf', $broker_check_targets, '_catch_errors' => true),
    default => undef,
  }
  $puppetdb_conf_raw = $broker_check_targets.size > 0 ? {
    true    => run_task('peadm_preflight::get_puppetdb_conf', $broker_check_targets, '_catch_errors' => true),
    default => undef,
  }
  $status_svc_raw = $all_targets.size > 0 ? {
    true    => run_task('peadm_preflight::get_status_services', $all_targets, '_catch_errors' => true),
    default => undef,
  }

  # Expected endpoints — allow primary or replica as valid targets (HA-safe)
  $all_primary_names = ($primary_target + $replica_target).unique
  $exp_broker_uris   = $all_primary_names.map |$p| { "wss://${p}:8142/pcp2/" }
  $exp_puppet_svrs   = $all_primary_names
  $exp_pdb_urls      = $all_primary_names.map |$p| { "https://${p}:8081" }

  # Validate broker URIs (compilers only)
  $broker_uri_failures = $broker_task_raw =~ NotUndef ? {
    true    => $broker_task_raw.ok_set.results.filter |$r| {
      $uris = $r.value['broker_uris']
      !($exp_broker_uris.any |$e| { $e in $uris })
    }.map |$r| {
      $uris = $r.value['broker_uris']
      "${r.target.name}: broker [${uris.join(', ')}] (expected one of: ${exp_broker_uris.join(', ')})"
    },
    default => [],
  }

  # Validate puppet server setting (compilers + replica)
  $puppet_svr_failures = $puppet_conf_raw =~ NotUndef ? {
    true    => $puppet_conf_raw.ok_set.results.filter |$r| {
      $svr = $r.value['server']
      $svr =~ NotUndef and !($exp_puppet_svrs.any |$e| { $svr == $e })
    }.map |$r| {
      "${r.target.name}: puppet server '${$r.value['server']}' (expected one of: ${exp_puppet_svrs.join(', ')})"
    },
    default => [],
  }

  # Validate PuppetDB server_urls (compilers + replica)
  $pdb_url_failures = $puppetdb_conf_raw =~ NotUndef ? {
    true    => $puppetdb_conf_raw.ok_set.results.filter |$r| {
      $urls = $r.value['server_urls']
      $r.value['present'] and $urls.size > 0 and !($exp_pdb_urls.any |$e| { $e in $urls })
    }.map |$r| {
      "${r.target.name}: puppetdb [${$r.value['server_urls'].join(', ')}] (expected one of: ${exp_pdb_urls.join(', ')})"
    },
    default => [],
  }

  $all_broker_failures = $broker_uri_failures + $puppet_svr_failures + $pdb_url_failures
  if $all_broker_failures.size > 0 {
    out::message("WARNING: Configuration drift detected:\n  ${all_broker_failures.join("\n  ")}")
  }

  # Build Mermaid topology model (used by HTML report)
  $status_by_name = $status_svc_raw =~ NotUndef ? {
    true    => $status_svc_raw.ok_set.results.reduce({}) |$m, $r| { $m + { $r.target.name => $r } },
    default => {},
  }
  $topo_nodes = (
    $primary_target.map         |$n| {
      $st = $status_by_name[$n]
      $sv = $st =~ NotUndef ? { true => $st.value['services'], default => {} }
      $er = $st =~ NotUndef ? { true => $st.value['errors'],   default => {} }
      $pn = { 'name' => $n, 'role' => 'primary',    'services' => $sv, 'errors' => $er }
      $pn
    } +
    $replica_target.map         |$n| {
      $st = $status_by_name[$n]
      $sv = $st =~ NotUndef ? { true => $st.value['services'], default => {} }
      $er = $st =~ NotUndef ? { true => $st.value['errors'],   default => {} }
      $rn = { 'name' => $n, 'role' => 'replica',    'services' => $sv, 'errors' => $er }
      $rn
    } +
    $compiler_target.map        |$n| {
      $st = $status_by_name[$n]
      $sv = $st =~ NotUndef ? { true => $st.value['services'], default => {} }
      $er = $st =~ NotUndef ? { true => $st.value['errors'],   default => {} }
      $cn = { 'name' => $n, 'role' => 'pe_compiler', 'services' => $sv, 'errors' => $er }
      $cn
    } +
    $all_postgresql_targets.map |$n| {
      $st = $status_by_name[$n]
      $sv = $st =~ NotUndef ? { true => $st.value['services'], default => {} }
      $er = $st =~ NotUndef ? { true => $st.value['errors'],   default => {} }
      $dbn = { 'name' => $n, 'role' => 'pe_postgres', 'services' => $sv, 'errors' => $er }
      $dbn
    }
  )
  $broker_by_name = $broker_task_raw =~ NotUndef ? {
    true    => $broker_task_raw.ok_set.results.reduce({}) |$m, $r| { $m + { $r.target.name => $r } },
    default => {},
  }
  $puppet_by_name = $puppet_conf_raw =~ NotUndef ? {
    true    => $puppet_conf_raw.ok_set.results.reduce({}) |$m, $r| { $m + { $r.target.name => $r } },
    default => {},
  }
  $pdb_by_name = $puppetdb_conf_raw =~ NotUndef ? {
    true    => $puppetdb_conf_raw.ok_set.results.reduce({}) |$m, $r| { $m + { $r.target.name => $r } },
    default => {},
  }
  $topo_edges = $compiler_target.map |$c| {
    $br = $broker_by_name[$c]
    $pp = $puppet_by_name[$c]
    $pd = $pdb_by_name[$c]
    $pcp_uris = $br =~ NotUndef ? {
      true    => $br.ok ? {
        true    => ($br.value['broker_uris'] =~ NotUndef ? { true => $br.value['broker_uris'], default => [] }),
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
        true    => ($pd.value['server_urls'] =~ NotUndef ? { true => $pd.value['server_urls'], default => [] }),
        default => [],
      },
      default => [],
    }
    $pcp_v = $exp_broker_uris.any |$e| { $e in $pcp_uris }
    $svr_v = $exp_puppet_svrs.any  |$e| { $e in $servers }
    $pdb_v = $exp_pdb_urls.any     |$e| { $e in $pdb_urls }
    [
      { 'from' => $c, 'kind' => 'pcp',           'valid' => $pcp_v, 'actual' => $pcp_uris, 'expected' => $exp_broker_uris },
      { 'from' => $c, 'kind' => 'puppet_server', 'valid' => $svr_v, 'actual' => $servers,  'expected' => $exp_puppet_svrs },
      { 'from' => $c, 'kind' => 'puppetdb',      'valid' => $pdb_v, 'actual' => $pdb_urls, 'expected' => $exp_pdb_urls   },
    ]
  }.flatten
  $topo_model      = { 'nodes' => $topo_nodes, 'edges' => $topo_edges }
  $mermaid_diagram = peadm_preflight::render_mermaid($topo_model)

  $ts_end = Timestamp()

  # ── Summary ────────────────────────────────────────────────────────────────
  $pass = '✓'
  $warn = '!'
  $fail = '✗'

  $pxp_summary = $compiler_target.size > 0 ? {
    true    => "${pass}  PXP-agent :8142    : all compilers can reach primary",
    default => "-   PXP-agent :8142    : skipped (no compilers)",
  }

  $fw_summary = $all_fw_failures.size > 0 ? {
    true    => "${fail}  Firewall rules     : ${all_fw_failures.size} blocked port(s)\n${
      $all_fw_failures.map |$f| { "           ⤷ ${f}" }.join("\n")
    }",
    default => "${pass}  Firewall rules     : all required ports open",
  }

  $db_summary = "${pass}  Database           : connectivity validated"

  $disk_summary = $disk_warnings.size > 0 ? {
    true    => "${warn}  Disk space         : ${disk_warnings.size} node(s) below minimum\n${
      $disk_warnings.map |$d| { "           ⤷ ${d}" }.join("\n")
    }",
    default => "${pass}  Disk space         : all nodes meet requirements",
  }

  $mem_summary = $mem_warnings.size > 0 ? {
    true    => "${warn}  Memory pressure    : ${mem_warnings.size} node(s) below minimum\n${
      $mem_warnings.map |$m| { "           ⤷ ${m}" }.join("\n")
    }",
    default => "${pass}  Memory pressure    : all nodes have sufficient memory",
  }

  $svc_summary = $all_svc_issues.size > 0 ? {
    true    => "${warn}  Service health     : ${all_svc_issues.size} issue(s) detected\n${
      $all_svc_issues.map |$s| { "           ⤷ ${s}" }.join("\n")
    }",
    default => "${pass}  Service health     : all services running",
  }

  $log_summary = $all_log_warnings.size > 0 ? {
    true    => "${warn}  Log errors         : ERROR/FATAL entries found in PE logs\n${
      $all_log_warnings.map |$l| {
        $l =~ /^  >> / ? { true => "              ${l.strip}", default => "           ⤷ ${l}" }
      }.join("\n")
    }",
    default => "${pass}  Log errors         : no recent ERROR/FATAL entries found",
  }

  $broker_summary = $broker_check_targets.size > 0 ? {
    true    => $all_broker_failures.size > 0 ? {
      true    => "${warn}  Broker config      : ${all_broker_failures.size} drift issue(s)\n${
        $all_broker_failures.map |$f| { "           ⤷ ${f}" }.join("\n")
      }",
      default => "${pass}  Broker config      : all compiler/replica configuration aligned",
    },
    default => "-   Broker config      : skipped (no compilers or replica)",
  }

  $warning_count = $all_fw_failures.size
    + $disk_warnings.size
    + $mem_warnings.size
    + $all_svc_issues.size
    + $all_log_warnings.size
    + $all_broker_failures.size

  out::message(@("SUMMARY"/$))
    ================================================
     Preflight Check Summary
    ================================================
    ${pass}  Node connectivity  : ${all_targets.size} target(s) reachable
    ${pxp_summary}
    ${fw_summary}
    ${db_summary}
    ${disk_summary}
    ${mem_summary}
    ${svc_summary}
    ${log_summary}
    ${broker_summary}
    ================================================
    | SUMMARY

  if $warning_count > 0 {
    out::message("! Preflight checks completed with ${warning_count} warning(s). Review the output above before proceeding.")
  } else {
    out::message("${pass} Preflight checks passed. Infrastructure is ready.")
  }

  # ── HTML report ────────────────────────────────────────────────────────────
  $effective_report_file = $html_report_file ? {
    undef => prompt('Save preflight results as an HTML report? Enter a file path (or leave blank to skip)'),
    default => $html_report_file,
  }

  unless $effective_report_file == '' or $effective_report_file =~ Undef {
    $status_label = $warning_count > 0 ? { true => "&#x26A0; ${warning_count} Warning(s)", default => '&#x2713; Passed' }

    $fmt           = '%Y-%m-%d %H:%M:%S UTC'
    $fmt_file      = '%Y-%m-%dT%H-%M-%S'
    $ts_start_s    = $ts_start.strftime($fmt)
    $ts_end_s      = $ts_end.strftime($fmt)
    $elapsed_s     = Integer($ts_end) - Integer($ts_start)
    $ts_file       = $ts_start.strftime($fmt_file)
    $effective_report_file_ts = regsubst($effective_report_file, /(\.[^.\/]+)$/, "-${ts_file}\\1")
    $ts_conn_s     = $ts_connectivity.strftime($fmt)
    $ts_pxp_s      = $ts_pxp.strftime($fmt)
    $ts_fw_s       = $ts_firewall.strftime($fmt)
    $ts_db_s       = $ts_db.strftime($fmt)
    $ts_disk_s     = $ts_disk.strftime($fmt)
    $ts_mem_s      = $ts_mem.strftime($fmt)
    $ts_svc_s      = $ts_svc.strftime($fmt)
    $ts_logs_s     = $ts_logs.strftime($fmt)
    $ts_broker_s   = $ts_broker.strftime($fmt)

    # Broker check rows
    $broker_rows = $broker_check_targets.size > 0 ? {
      true    => $all_broker_failures.size > 0 ? {
        true    => $all_broker_failures.map |$f| { "<tr><td class='warn'>&#x26A0;</td><td>${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>All compiler/replica configuration aligned with primary</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>Skipped (no compilers or replica configured)</td></tr>",
    }

    # Per-node broker/conf detail for expandable section
    $broker_node_details = $broker_check_targets.size > 0 ? {
      true    => $broker_check_targets.map |$node| {
        $br = $broker_by_name[$node]
        $pp = $puppet_by_name[$node]
        $pd = $pdb_by_name[$node]
        $broker_val = $br =~ NotUndef ? {
          true    => $br.ok ? {
            true    => ($br.value['broker_uris'] =~ NotUndef ? {
              true    => $br.value['broker_uris'].join(', '),
              default => ($br.value['broker_uri'] =~ NotUndef ? { true => $br.value['broker_uri'], default => '(empty)' }),
            }),
            default => "(task failed)",
          },
          default => 'n/a',
        }
        $server_val = $pp =~ NotUndef ? {
          true    => $pp.ok ? {
            true    => ($pp.value['server'] =~ NotUndef ? { true => $pp.value['server'], default => '(not set)' }),
            default => "(task failed)",
          },
          default => 'n/a',
        }
        $pdb_val = $pd =~ NotUndef ? {
          true    => $pd.ok ? {
            true    => ($pd.value['server_urls'] =~ NotUndef ? {
              true    => ($pd.value['server_urls'].size > 0 ? { true => $pd.value['server_urls'].join(', '), default => '(not set)' }),
              default => '(not set)',
            }),
            default => "(task failed)",
          },
          default => 'n/a',
        }
        $node_issues = $all_broker_failures.filter |$f| { $f =~ Regexp("^${node}:") }.size
        $sum_cls = $node_issues > 0 ? { true => 'warn', default => 'pass' }
        $sum_ico = $node_issues > 0 ? { true => '&#x26A0;', default => '&#x2713;' }
        $sum_txt = $node_issues > 0 ? { true => "${node_issues} drift issue(s)", default => 'aligned' }
        $detail_rows = "<tr><td class='conf-label'>Broker URI(s)</td><td class='chip-cell'>${broker_val}</td></tr><tr><td class='conf-label'>Puppet server</td><td class='chip-cell'>${server_val}</td></tr><tr><td class='conf-label'>PuppetDB URL(s)</td><td class='chip-cell'>${pdb_val}</td></tr>"
        "<details class='node-detail'><summary><span class='${sum_cls}'>${sum_ico}</span> <span class='node-name'>${node}</span><span class='svc-count ${sum_cls}'>${sum_txt}</span></summary><table class='svc-table detail-table'>${detail_rows}</table></details>"
      }.join("\n"),
      default => "<div style='padding:1em 1.25em;color:#b0aacf;font-size:0.88em'>Skipped (no compilers or replica configured)</div>",
    }

    $fw_443_row = $firewall_infra_targets.size > 0 ? {
      true => $fw_443_failures.size > 0 ? {
        true    => $fw_443_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:443 (HTTPS/Console) — ${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>:443 (HTTPS/Console) — all infra nodes reachable</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>:443 (HTTPS/Console) — skipped (no replica/compilers)</td></tr>",
    }
    $fw_4433_row = $firewall_infra_targets.size > 0 ? {
      true => $fw_4433_failures.size > 0 ? {
        true    => $fw_4433_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:4433 (Classifier API) — ${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>:4433 (Classifier API) — all infra nodes reachable</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>:4433 (Classifier API) — skipped (no replica/compilers)</td></tr>",
    }
    $fw_8081_row = $fw_8081_failures.size > 0 ? {
      true    => $fw_8081_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:8081 (PuppetDB) — ${f}</td></tr>" }.join("\n"),
      default => $firewall_infra_targets.size > 0 ? {
        true    => "<tr><td class='pass'>&#x2713;</td><td>:8081 (PuppetDB) — all infra nodes reachable</td></tr>",
        default => "<tr><td class='skip'>-</td><td>:8081 (PuppetDB) — skipped (no replica/compilers)</td></tr>",
      },
    }
    $fw_8140_row = $fw_8140_failures.size > 0 ? {
      true    => $fw_8140_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:8140 (Puppet Server) — ${f}</td></tr>" }.join("\n"),
      default => $firewall_infra_targets.size > 0 ? {
        true    => "<tr><td class='pass'>&#x2713;</td><td>:8140 (Puppet Server) — all infra nodes reachable</td></tr>",
        default => "<tr><td class='skip'>-</td><td>:8140 (Puppet Server) — skipped (no replica/compilers)</td></tr>",
      },
    }
    $fw_8143_row = $firewall_infra_targets.size > 0 ? {
      true => $fw_8143_failures.size > 0 ? {
        true    => $fw_8143_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:8143 (Orchestrator/PCP) — ${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>:8143 (Orchestrator/PCP) — all infra nodes reachable</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>:8143 (Orchestrator/PCP) — skipped (no replica/compilers)</td></tr>",
    }
    $fw_8170_row = $firewall_infra_targets.size > 0 ? {
      true => $fw_8170_failures.size > 0 ? {
        true    => $fw_8170_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:8170 (Code Manager) — ${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>:8170 (Code Manager) — all infra nodes reachable</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>:8170 (Code Manager) — skipped (no replica/compilers)</td></tr>",
    }
    $fw_5432_row = $primary_postgresql_target.size > 0 ? {
      true => $fw_5432_failures.size > 0 ? {
        true    => $fw_5432_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:5432 (PostgreSQL) — ${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>:5432 (PostgreSQL) — primary can reach psql node</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>:5432 (PostgreSQL) — skipped (no external PostgreSQL node)</td></tr>",
    }
    $fw_rows = "${fw_443_row}\n${fw_4433_row}\n${fw_8081_row}\n${fw_8140_row}\n${fw_8143_row}\n${fw_8170_row}\n${fw_5432_row}"
    $disk_rows = $disk_warnings.size > 0 ? {
      true    => $disk_warnings.map |$d| { "<tr><td class='warn'>&#x26A0;</td><td>${d}</td></tr>" }.join("\n"),
      default => "<tr><td class='pass'>&#x2713;</td><td>All nodes meet requirements</td></tr>",
    }
    $mem_rows = $mem_warnings.size > 0 ? {
      true    => $mem_warnings.map |$m| { "<tr><td class='warn'>&#x26A0;</td><td>${m}</td></tr>" }.join("\n"),
      default => "<tr><td class='pass'>&#x2713;</td><td>All nodes have sufficient memory</td></tr>",
    }
    $svc_rows = $all_svc_issues.size > 0 ? {
      true    => $all_svc_issues.map |$s| { "<tr><td class='warn'>&#x26A0;</td><td>${s}</td></tr>" }.join("\n"),
      default => "<tr><td class='pass'>&#x2713;</td><td>All services running</td></tr>",
    }

    $ts_svc_detail_s = $ts_svc_detail.strftime($fmt)
    $svc_node_details = $svc_detail_results.ok_set.results.map |$r| {
      $node = $r.target.name
      $lines = $r['stdout'].strip.split("\n").filter |$l| { $l.strip != '' }
      $service_rows = $lines.map |$l| {
        $parts = $l.split(' ')
        $svc  = $parts[0]
        $st   = $parts.size > 1 ? { true => $parts[1], default => 'unknown' }
        $cls  = $st == 'active' ? { true => 'pass', default => 'fail' }
        $ico  = $st == 'active' ? { true => "&#x2713;", default => "&#x2717;" }
        "<tr><td class='${cls}'>${ico}</td><td class='svc-name'>${svc}</td><td class='${cls} svc-status'>${st}</td></tr>"
      }.join("")
      $issues = $lines.filter |$l| { $l !~ / active/ }.size
      $sum_cls = $issues > 0 ? { true => 'warn', default => 'pass' }
      $sum_ico = $issues > 0 ? { true => "&#x26A0;", default => "&#x2713;" }
      $sum_txt = $issues > 0 ? { true => "${issues} issue(s)", default => "${lines.size} service(s) active" }
      "<details class='node-detail'><summary><span class='${sum_cls}'>${sum_ico}</span> <span class='node-name'>${node}</span><span class='svc-count ${sum_cls}'>${sum_txt}</span></summary><table class='svc-table'>${service_rows}</table></details>"
    }.join("\n")

    $all_log_results = $primary_log_cmd.ok_set.results + $compiler_log_raw + $postgresql_log_raw
    $log_node_details = $all_log_results.map |$r| {
      $node = $r.target.name
      $raw  = $r['stdout'].strip
      if $raw == '' {
        "<details class='node-detail'><summary><span class='pass'>&#x2713;</span> <span class='node-name'>${node}</span><span class='svc-count pass'>No recent errors</span></summary></details>"
      } else {
        $lines     = $raw.split("\n")
        $log_count = $lines.filter |$l| { $l !~ /^  / and $l.strip != '' }.size
        $err_count = $lines.filter |$l| { $l =~ /^  >> / }.size
        $body = $lines.map |$l| {
          $is_err  = $l =~ /^  >> /
          $cleaned = $is_err ? { true => regsubst($l, /^  >> /, ''), default => $l }
          $safe    = regsubst(regsubst(regsubst($cleaned, /&/, '&amp;', 'G'), /</, '&lt;', 'G'), />/, '&gt;', 'G')
          $is_err ? {
            true    => "<div class='log-line'>${safe}</div>",
            default => "<div class='log-header-line'>&#x26A0; ${safe}</div>",
          }
        }.join("")
        "<details class='node-detail'><summary><span class='warn'>&#x26A0;</span> <span class='node-name'>${node}</span><span class='svc-count warn'>${log_count} log(s), ${err_count} sample line(s)</span></summary><div class='log-content'>${body}</div></details>"
      }
    }.join("\n")
    $fw_8142_row = $compiler_target.size > 0 ? {
      true => $pxp_failures.size > 0 ? {
        true    => $pxp_failures.map |$f| { "<tr><td class='fail'>&#x2717;</td><td>:8142 (PXP/Orchestrator) — ${f}</td></tr>" }.join("\n"),
        default => "<tr><td class='pass'>&#x2713;</td><td>:8142 (PXP/Orchestrator) — all compilers can reach primary</td></tr>",
      },
      default => "<tr><td class='skip'>-</td><td>:8142 (PXP/Orchestrator) — skipped (no compilers)</td></tr>",
    }

    $badge_class = $warning_count > 0 ? { true => 'badge-warn', default => 'badge-pass' }

    $html = @("HTML"/$)
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Puppet Preflight Report</title>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <script>mermaid.initialize({ startOnLoad: true, theme: 'base', themeVariables: { fontSize: '13px' } });</script>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          body { font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f4fb; color: #1a1a2e; min-height: 100vh; }
          /* ── Header ── */
          .header { background: radial-gradient(ellipse at 65% 40%, #4d2de8 0%, #1a0a6b 55%, #060330 100%); padding: 2.5em 2em 2.2em; color: #fff; }
          .header-inner { max-width: 980px; margin: 0 auto; }
          .brand { font-size: 0.72em; font-weight: 500; letter-spacing: 0.14em; text-transform: uppercase; opacity: 0.6; margin-bottom: 0.4em; }
          .product { font-size: 2em; font-weight: 700; letter-spacing: -0.01em; display: flex; align-items: center; gap: 0.4em; margin-bottom: 0.8em; }
          .product svg { width: 1.1em; height: 1.1em; }
          .report-title { font-size: 1em; font-weight: 500; opacity: 0.85; margin-bottom: 0.6em; }
          .badge { display: inline-flex; align-items: center; gap: 0.35em; padding: 0.28em 0.85em; border-radius: 999px; font-size: 0.82em; font-weight: 600; margin-left: 0.5em; vertical-align: middle; }
          .badge-pass { background: rgba(0,210,130,0.18); color: #00e09a; border: 1px solid rgba(0,210,130,0.35); }
          .badge-warn { background: rgba(255,160,0,0.18); color: #ffb930; border: 1px solid rgba(255,160,0,0.35); }
          .meta { font-size: 0.76em; opacity: 0.85; margin-top: 1em; line-height: 1.8; font-family: 'SFMono-Regular', Consolas, monospace; }
          .meta span { opacity: 0.5; margin: 0 0.4em; }
          /* ── Content ── */
          .content { max-width: 980px; margin: 2em auto; padding: 0 1.5em 3em; }
          /* ── Section cards ── */
          .section { background: #fff; border: 1px solid #e4e2f0; border-radius: 10px; margin-bottom: 1.1em; box-shadow: 0 2px 8px rgba(20,10,80,0.05); overflow: hidden; }
          .section-header { display: flex; align-items: center; justify-content: space-between; padding: 0.85em 1.25em; background: #faf9fd; border-bottom: 1px solid #eeeaf8; }
          .section-title { font-size: 0.75em; font-weight: 600; text-transform: uppercase; letter-spacing: 0.1em; color: #3d2bab; display: flex; align-items: center; gap: 0.5em; }
          .section-title .icon { font-size: 1.2em; }
          .ts { font-size: 0.78em; font-weight: 400; color: #b0aacf; font-family: 'SFMono-Regular', Consolas, monospace; }
          /* ── Table ── */
          table { width: 100%; border-collapse: collapse; }
          td { padding: 0.65em 1.25em; border-bottom: 1px solid #f3f1fb; vertical-align: top; font-size: 0.88em; line-height: 1.5; }
          tr:last-child td { border-bottom: none; }
          td:first-child { width: 2.2em; text-align: center; font-size: 1em; padding-right: 0; }
          td pre { margin: 0.3em 0 0; font-size: 0.82em; white-space: pre-wrap; font-family: 'SFMono-Regular', Consolas, monospace; color: #5a5880; background: #f8f7fc; border-radius: 4px; padding: 0.4em 0.6em; }
          thead th { font-size: 0.72em; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: #9590bb; padding: 0.5em 1.25em; background: #f8f7fc; border-bottom: 1px solid #eeeaf8; text-align: left; }
          thead th:first-child { width: 2.2em; text-align: center; padding-right: 0; }
          tr:hover td { background: #faf9fd; }
          /* ── Status colours ── */
          .pass { color: #00965a; }
          .warn { color: #c87000; }
          .fail { color: #c52626; }
          .skip { color: #b0aacf; }
          /* ── Targets chip ── */
          .chip { display: inline-block; background: rgba(61,43,171,0.08); color: #3d2bab; border-radius: 4px; padding: 0.1em 0.45em; font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.9em; }
          /* ── Footer ── */
          footer { text-align: center; padding: 2em; font-size: 0.75em; color: #b0aacf; border-top: 1px solid #e4e2f0; margin-top: 1em; }
          footer a { color: #3d2bab; text-decoration: none; }
          /* ── Expandable node details ── */
          .node-detail { border-bottom: 1px solid #f3f1fb; }
          .node-detail:last-child { border-bottom: none; }
          .node-detail summary { display: flex; align-items: center; gap: 0.6em; padding: 0.75em 1.25em; cursor: pointer; list-style: none; font-size: 0.88em; user-select: none; }
          .node-detail summary::-webkit-details-marker { display: none; }
          .node-detail summary::before { content: '▶'; font-size: 0.65em; color: #b0aacf; transition: transform 0.15s; flex-shrink: 0; }
          .node-detail[open] summary::before { transform: rotate(90deg); }
          .node-detail summary:hover { background: #faf9fd; }
          .node-name { font-family: 'SFMono-Regular', Consolas, monospace; font-weight: 500; flex: 1; }
          .svc-count { font-size: 0.82em; color: #9590bb; margin-left: auto; }
          .svc-count.warn { color: #c87000; }
          .svc-count.fail { color: #c52626; }
          .svc-table { margin: 0; border-top: 1px solid #eeeaf8; }
          .svc-table td { padding: 0.45em 1.5em; font-size: 0.83em; border-bottom: 1px solid #f8f7fc; }
          .svc-table tr:last-child td { border-bottom: none; }
          .svc-table td:first-child { width: 2em; padding-left: 2.5em; color: inherit; }
          .svc-name { font-family: 'SFMono-Regular', Consolas, monospace; color: #3d3560; }
          .svc-status { font-size: 0.85em; color: #9590bb; text-align: right; }
          .svc-status.pass { color: #00965a; }
          .svc-status.fail { color: #c52626; }
          /* ── Log error content ── */
          .log-content { border-top: 1px solid #eeeaf8; padding: 0.75em 1.5em 0.75em 2.5em; }
          .log-header-line { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.8em; font-weight: 600; color: #c87000; margin: 0.8em 0 0.25em; padding: 0.2em 0; border-top: 1px solid #f3f1fb; }
          .log-header-line:first-child { border-top: none; margin-top: 0; }
          .log-line { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.77em; color: #5a5880; background: #f8f7fc; border-radius: 3px; padding: 0.25em 0.5em; margin: 0.15em 0; white-space: pre-wrap; word-break: break-all; }
          /* ── Broker / conf detail ── */
          .detail-table td { font-size: 0.83em; }
          .conf-label { width: 8em; color: #9590bb; font-weight: 500; font-size: 0.83em; }
          .chip-cell { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.88em; color: #3d3560; word-break: break-all; }
          /* ── Mermaid topology ── */
          .mermaid-container { padding: 1.25em; overflow-x: auto; text-align: center; }
          .mermaid { background: transparent; display: inline-block; max-width: 100%; }
          /* ── Open-in-tab button ── */
          .open-tab-btn { background: rgba(61,43,171,0.08); color: #3d2bab; border: 1px solid rgba(61,43,171,0.2); border-radius: 6px; padding: 0.28em 0.75em; font-size: 0.75em; font-weight: 600; cursor: pointer; letter-spacing: 0.04em; font-family: inherit; white-space: nowrap; }
          .open-tab-btn:hover { background: rgba(61,43,171,0.15); border-color: rgba(61,43,171,0.35); }
        </style>
      </head>
      <body>
        <div class="header">
          <div class="header-inner">
            <div class="brand">perforce</div>
            <div class="product">
              <svg viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 4l8 5-8 5V4z" fill="#00c7e6"/><path d="M8 14l8 5-8 5V14z" fill="#00c7e6" opacity=".6"/><path d="M18 9l8 5-8 5V9z" fill="#fff" opacity=".9"/></svg>
              Puppet
            </div>
            <div class="report-title">PE Infrastructure Preflight Report <span class="${badge_class} badge">${status_label}</span></div>
            <div class="meta">
              Started: ${ts_start_s}<span>|</span>Completed: ${ts_end_s}<span>|</span>Elapsed: ${elapsed_s}s<br>
              Primary: <span class="chip" style="background:rgba(255,255,255,0.15);color:#e8e4ff;">${primary_host}</span>
            </div>
          </div>
        </div>

        <div class="content">

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F4E1;</span> Node Connectivity</div>
              <span class="ts">${ts_conn_s}</span>
            </div>
            <table><tr><td class="pass">&#x2713;</td><td>${all_targets.size} target(s) reachable: <span class="chip">${all_targets.join('</span> <span class="chip">')}</span></td></tr></table>
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F6E1;</span> Firewall &amp; Port Connectivity</div>
              <span class="ts">${ts_fw_s}</span>
            </div>
            <table>
              <thead><tr><th></th><th>Port &amp; Service</th></tr></thead>
              ${fw_443_row}
              ${fw_4433_row}
              ${fw_8081_row}
              ${fw_8140_row}
              ${fw_8142_row}
              ${fw_8143_row}
              ${fw_8170_row}
              ${fw_5432_row}
            </table>
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F4BE;</span> Disk Space</div>
              <span class="ts">${ts_disk_s}</span>
            </div>
            <table>${disk_rows}</table>
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F9E0;</span> Memory Pressure</div>
              <span class="ts">${ts_mem_s}</span>
            </div>
            <table>${mem_rows}</table>
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x2699;&#xFE0F;</span> Service Health</div>
              <span class="ts">${ts_svc_s}</span>
            </div>
            <table>${svc_rows}</table>
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F4CA;</span> PE Services per Node</div>
              <span class="ts">${ts_svc_detail_s}</span>
            </div>
            ${svc_node_details}
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F4CB;</span> Log Errors per Node</div>
              <span class="ts">${ts_logs_s}</span>
            </div>
            ${log_node_details}
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F517;</span> Broker &amp; Configuration Check</div>
              <span class="ts">${ts_broker_s}</span>
            </div>
            <table>${broker_rows}</table>
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F4CA;</span> Configuration per Node</div>
              <span class="ts">${ts_broker_s}</span>
            </div>
            ${broker_node_details}
          </div>

          <div class="section">
            <div class="section-header">
              <div class="section-title"><span class="icon">&#x1F5FA;&#xFE0F;</span> PE Topology Map</div>
              <div style="display:flex;align-items:center;gap:1em">
                <button class="open-tab-btn" onclick="openTopologyMap()">Open full size &#x2197;</button>
                <span class="ts">${ts_broker_s}</span>
              </div>
            </div>
            <div class="mermaid-container">
              <pre class="mermaid">${mermaid_diagram}</pre>
              <textarea id="topo-source" style="display:none">${mermaid_diagram}</textarea>
            </div>
          </div>

        </div>
        <footer>
          Puppet PE Preflight &mdash; <a href="https://portal.perforce.com/s/product/a3g4X000009wMFBQA2/puppet">Perforce Customer Portal</a>
          &nbsp;&middot;&nbsp; &copy; Perforce Software, Inc.
        </footer>
        <script>
          function openTopologyMap() {
            var src = document.getElementById('topo-source').value;
            var newWin = window.open('', '_blank');
            var page = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>PE Topology Map<\/title>'
              + '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap">'
              + '<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"><\/script>'
              + '<script>mermaid.initialize({startOnLoad:true,theme:"base",themeVariables:{fontSize:"14px"}});<\/script>'
              + '<style>'
              + 'body{margin:0;padding:2.5em 3em;background:#f5f4fb;font-family:Inter,-apple-system,sans-serif}'
              + 'h2{color:#3d2bab;font-size:0.8em;font-weight:600;text-transform:uppercase;letter-spacing:0.1em;margin-bottom:1.5em}'
              + '.wrap{background:#fff;border:1px solid #e4e2f0;border-radius:10px;box-shadow:0 2px 8px rgba(20,10,80,0.05);padding:2.5em;overflow-x:auto}'
              + '<\/style><\/head><body>'
              + '<h2>&#x1F5FA;&#xFE0F; PE Topology Map<\/h2>'
              + '<div class="wrap"><div class="mermaid">' + src + '<\/div><\/div>'
              + '<\/body><\/html>';
            newWin.document.write(page);
            newWin.document.close();
          }
        </script>
      </body>
      </html>
      | HTML

    file::write($effective_report_file_ts, $html)
    out::message("HTML report written to: ${effective_report_file_ts}")

    $text_status_line = $warning_count > 0 ? {
      true    => "! ${warning_count} WARNING(S) — review issues before proceeding",
      default => "${pass} PASSED — infrastructure is ready",
    }
    $text_report_file = regsubst($effective_report_file_ts, /\.html$/, '.txt')
    $text_report = @("TEXT"/$)
      ================================================
        Puppet PE Infrastructure Preflight Report
      ================================================
      Primary   : ${primary_host}
      Started   : ${ts_start_s}
      Completed : ${ts_end_s}
      Elapsed   : ${elapsed_s}s
      Status    : ${text_status_line}
      Broker & Configuration
        ${broker_summary}

      ================================================

      Node Connectivity
        ${pass} ${all_targets.size} target(s) reachable: ${all_targets.join(', ')}

      PXP-Agent Connectivity (:8142)
        ${pxp_summary}

      Firewall & Port Connectivity
      ${fw_summary}

      Database
        ${db_summary}

      Disk Space
        ${disk_summary}

      Memory Pressure
        ${mem_summary}

      Service Health
        ${svc_summary}

      Log Errors
        ${log_summary}

      ================================================
      ${text_status_line}
      ================================================
      | TEXT
    file::write($text_report_file, $text_report)
    out::message("Text summary written to: ${text_report_file}")
  }

  if $warning_count > 0 {
    return("Preflight checks completed with ${warning_count} warning(s). Review the summary above before proceeding.")
  }
  return("Preflight checks passed. Infrastructure is ready for peadm::install or peadm::upgrade.")
}
