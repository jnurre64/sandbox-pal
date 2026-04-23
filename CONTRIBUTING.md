# Contributing to sandbox-pal

Thank you for contributing to sandbox-pal!

## Workflow

1. Fork the repository and create a feature branch from `main`
2. Branch naming: `feat/`, `fix/`, or `docs/` prefix, kebab-case (e.g. `feat/async-mode`)
3. Commit style: conventional commits — `feat:`, `fix:`, `docs:`, `test:`, `chore:`
4. Open a pull request against `main` when ready

## Running tests

```bash
# Lint all shell scripts
shellcheck $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*')

# Run the BATS test suite
bats tests/
```

All shell scripts must pass `shellcheck` with zero warnings and use `set -euo pipefail`.

## PR checklist

- [ ] `shellcheck` passes with zero warnings
- [ ] `bats tests/` passes
- [ ] CHANGELOG.md updated for any user-facing changes
- [ ] No credentials or tokens committed

## Reporting issues

Use [GitHub Issues](https://github.com/jnurre64/sandbox-pal/issues). Search before filing to avoid duplicates. Include your OS, Docker version, and the relevant log output from `~/.pal/runs/`.
