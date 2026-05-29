# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - Unreleased

### Added
- New `get_status_services` task: probes the PE `/status/v1/services` endpoint on
  puppetserver (8140), puppetdb (8081), console-services (4433), and orchestrator (8143)
  over HTTPS-to-localhost, aggregates service states, and records per-port errors. Ports
  that don't respond are recorded as errors rather than failures (a compiler legitimately
  does not run console-services or orchestrator).
- `peadm_preflight::topology_map` plan now attaches a `services` and `errors` hash to
  each node in the topology model.
- `peadm_preflight::render_mermaid` decorates node labels with a `DEGRADED: svc=state`
  line when any returned service is not in the `running` state. Nodes without a
  `services` field render exactly as before — full backward compatibility.

## [0.1.0] - 2026-05-28

### Added
- Initial module scaffold for peadm_preflight
- Placeholder for database connectivity checks
- Placeholder for database performance validation
- Module metadata and documentation

### Todo
- Implement actual preflight check logic from peadm fork
- Add database connectivity validation
- Add database performance metrics collection
- Add comprehensive test suite
- Add integration tests with PEADM

