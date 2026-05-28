# PEADM Preflight Module Setup Guide

## Module Created

The `peadm_preflight` module has been created at `.modules/peadm_preflight/` with the following structure:

```
.modules/peadm_preflight/
├── metadata.json          # Module metadata
├── README.md              # Documentation
├── LICENSE                # Apache 2.0 license
├── CHANGELOG.md           # Version history
├── CONTRIBUTING.md        # Contribution guidelines
├── plans/
│   └── check.pp           # Main preflight plan (placeholder)
├── functions/
│   ├── db_connectivity.pp # DB connectivity checks (placeholder)
│   └── db_performance.pp  # DB performance checks (placeholder)
└── data/
    └── common.yaml        # Configuration defaults
```

## Next Steps

### 1. Extract Preflight Checks from PEADM Fork

Copy the actual preflight check implementations from your peadm fork (`cwebster61083/puppetlabs-peadm`) into:
- `plans/check.pp` — Main plan logic
- `functions/db_connectivity.pp` — Database connectivity tests
- `functions/db_performance.pp` — Performance metrics collection

### 2. Create GitHub Repository

```bash
# Initialize git in the module directory
cd .modules/peadm_preflight
git init
git add .
git commit -m "Initial commit: peadm_preflight module scaffold"

# Create repo on GitHub and push
git remote add origin https://github.com/yourusername/peadm_preflight.git
git branch -M main
git push -u origin main
```

### 3. Update Puppetfile

Modify your `Puppetfile` to use the new standalone module:

```ruby
# Remove the forked peadm with preflight checks
# mod 'puppetlabs/peadm',
#   git: 'https://github.com/cwebster61083/puppetlabs-peadm.git',
#   branch: 'preflight-checks'

# Use standard peadm
mod 'puppetlabs/peadm',
  git: 'https://github.com/puppetlabs/puppetlabs-peadm.git'

# Add the new standalone preflight module
mod 'peadm_preflight',
  git: 'https://github.com/yourusername/peadm_preflight.git',
  branch: 'main'
```

### 4. Update Bolt Configuration

Call the new module's plan in your bolt commands:

```bash
# Run preflight checks
bolt plan run peadm_preflight::check targets=peadm_nodes

# Or with strict mode
bolt plan run peadm_preflight::check targets=peadm_nodes strict=true
```

### 5. Remove Git Config Copy from setup_pe_lab.sh

(Already done in previous changes)

## Testing the Module Locally

Before pushing to GitHub, test it locally:

```bash
# From project root
bolt plan run peadm_preflight::check targets=peadm_nodes
```

## Module Development

When implementing the actual check functions, use Puppet's Bolt task execution:

```puppet
plan peadm_preflight::check(TargetSpec $targets) {
  # Run database connectivity check
  $connectivity_results = run_command('psql -h db_host -c SELECT 1', $targets)
  
  # Collect performance metrics
  $performance_results = run_command('fio --eta=always', $targets)
  
  return {
    connectivity => $connectivity_results,
    performance  => $performance_results,
  }
}
```

