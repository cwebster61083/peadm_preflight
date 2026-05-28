# Contributing to peadm_preflight

Thank you for your interest in contributing! This module accepts pull requests and bug reports.

## Development Setup

```bash
git clone https://github.com/yourusername/peadm_preflight.git
cd peadm_preflight
bundle install
bundle exec rake validate
bundle exec rake lint
bundle exec rake spec
```

## Testing

Ensure all tests pass before submitting a PR:

```bash
bundle exec rake test
```

## Code Style

- Follow Puppet style guide: https://puppet.com/docs/puppet/latest/style_guide.html
- Run `bundle exec rake lint` to validate
- Run `bundle exec puppet-lint` for additional checks

## Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Submit a Pull Request

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
