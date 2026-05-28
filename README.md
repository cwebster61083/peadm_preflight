# peadm_preflight

A Puppet module that provides preflight checks for Puppet Enterprise PEADM deployments.

## Features

- Database connectivity checks (PE Primary → PostgreSQL)
- Database performance validation (disk throughput, I/O wait times)
- Network connectivity verification
- System resource availability checks

## Usage

### Bolt Plan

Run the preflight checks against PE infrastructure:

```bash
bolt plan run peadm_preflight::check targets=peadm_nodes
```

### With Parameters

```bash
bolt plan run peadm_preflight::check \
  targets=peadm_nodes \
  strict=true \
  verbose=true
```

## Plans

### `peadm_preflight::check`

Runs comprehensive preflight checks on PE infrastructure.

**Parameters:**
- `targets` (TargetSpec): Target nodes to check (typically PE servers and PostgreSQL nodes)
- `strict` (Boolean): Fail on warnings (default: false)
- `verbose` (Boolean): Verbose output (default: true)

## Installation

Add to your `Puppetfile`:

```ruby
mod 'peadm_preflight',
  git: 'https://github.com/yourusername/peadm_preflight.git',
  branch: 'main'
```

Then install modules:

```bash
bolt module install
```

## Module Structure

```
peadm_preflight/
├── plans/
│   └── check.pp           # Main preflight plan
├── functions/
│   ├── db_connectivity.pp # Database connectivity checks
│   └── db_performance.pp  # Database performance checks
├── data/
│   └── common.yaml        # Configuration defaults
└── metadata.json          # Module metadata
```

## Requirements

- Puppet >= 7.0.0
- Bolt >= 3.0.0
- Ruby >= 2.7

## License

Apache License 2.0
