# Rename claude-pal → sandbox-pal (brand-only) — Design

**Status:** Approved 2026-04-23
**Issue:** —
**Supersedes:** —

## Goal

Rename the product brand from `claude-pal` to `sandbox-pal` across the repository and GitHub, without touching the `pal-*` command/skill namespace, the `PAL_*` env vars, the `.pal/` per-repo config dir, or the version number. After this change, the plugin, Docker artifacts, host config path, manifests, and docs consistently say `sandbox-pal`; the user-visible CLI surface (slash commands, env vars, repo-local config) is byte-for-byte identical to before.

## Non-goals

- Renaming any `pal-*` command, skill, `PAL_*` env var, or the `.pal/` per-repo config directory.
- Bumping the version. `plugin.json`'s `version` stays at `0.5.0` through this change.
- Renaming the sibling repo `jnurre64/claude-pal-action`.
- Renaming the GitHub PAT `claude-pal-token` or its local file path `~/.config/gh-tokens/claude-pal-token`.
- Rewriting git history or force-moving existing `v0.4.0` / `v0.5.0` tags. Those tags remain pointing at commits that say `name: "claude-pal"` in `plugin.json`; the marketplace pin is moved off them (see below).
- Automating user-side state migration. Migration steps are documented in CHANGELOG; users run them manually.

## Architecture

Brand-only substitution. The literal string `claude-pal` is replaced with `sandbox-pal` wherever it identifies this product — plugin identity, Docker image/volume namespace, host config path, and documentation. Commands, skills, env vars, and repo-local dirs keep their `pal-*` / `PAL_*` / `.pal/` prefixes; these were already Claude-agnostic and independent of the repo brand.

Replacement is **mechanical** across in-repo files. Exceptions (things that intentionally stay `claude-pal`):

- The sibling repo reference `jnurre64/claude-pal-action` wherever it appears in docs.
- The PAT filename `claude-pal-token` wherever documented.
- Historical commit messages and release tags (immutable).

Exceptions are enforced by review, not by tooling — there are few enough of them (roughly a dozen references) to eyeball.

## Substitution map

| From | To | Locations |
|---|---|---|
| `claude-pal` (plugin name) | `sandbox-pal` | `.claude-plugin/plugin.json` (`name`, `repository`), `.claude-plugin/marketplace.json` (`name`, nested `plugins[].name`, `source.repo`, `homepage`, `metadata.description`) |
| `claude-pal:latest`, `claude-pal:dev` | `sandbox-pal:latest`, `sandbox-pal:dev` | `lib/image.sh`, `image/opt/pal/*.sh`, tests, docs |
| `claude-pal-claude` (volume) | `sandbox-pal-claude` | `lib/workspace.sh`, tests, docs |
| `claude-pal-workspace` (volume/container) | `sandbox-pal-workspace` | `lib/workspace.sh`, tests, docs |
| `~/.config/claude-pal` | `~/.config/sandbox-pal` | `lib/config.sh`, docs |
| `jnurre64/claude-pal` (URL) | `jnurre64/sandbox-pal` | README, docs, manifests, CHANGELOG (going-forward refs) |
| `claude-pal` (prose brand in docs) | `sandbox-pal` | README, CLAUDE.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, UPSTREAM.md, `docs/install.md`, `docs/authentication.md`, design/plan docs |
| Filenames `*claude-pal*.md` under `docs/superpowers/` | `*sandbox-pal*.md` | `git mv` (three files: `specs/2026-04-18-claude-pal-design.md`, `plans/2026-04-18-claude-pal.md`, `plans/2026-04-21-claude-pal-auth-rework.md`) |

## Marketplace pin strategy

`.claude-plugin/marketplace.json` currently pins `plugins[0].source.ref: "v0.5.0"`. That tag's committed `plugin.json` says `name: "claude-pal"` and cannot be rewritten without force-moving the tag (out of scope). After the rename, a fresh install via the renamed marketplace would therefore install a `claude-pal`-named plugin from a `sandbox-pal`-named marketplace — inconsistent.

**Decision:** set `ref: "main"` in `marketplace.json` as part of this PR. This tracks the renamed branch immediately. The next real feature release (v0.6.0 or later) will tag a commit whose `plugin.json` already says `sandbox-pal`, and the pin can be moved back to that tag at release time.

**Trade-off accepted:** users installing from `main` get an unversioned moving target until the next tag. Acceptable because the project is personal-use scale and the alternative (force-moving `v0.5.0`) is worse.

## GitHub rename procedure

Executed by the user after the rename PR merges:

1. PR on branch `rename-to-sandbox-pal` lands on `main`.
2. GitHub UI: `jnurre64/claude-pal` → Settings → Rename to `sandbox-pal`. GitHub preserves stars, issues, PRs, releases, and auto-redirects old URLs and git remotes.
3. Locally: `git remote set-url origin https://github.com/jnurre64/sandbox-pal.git`.
4. Optional: rename the working directory `~/repos/claude-pal` → `~/repos/sandbox-pal`.
5. Verify: `git fetch` via both the old and new URL succeeds; the old URL redirects to the new.

The repo rename itself is not performed by this PR — the PR only lands the in-repo substitutions. GitHub-side rename is a one-click manual step.

## User migration (documented in CHANGELOG)

Existing users of `claude-pal` have three pieces of state the rename orphans. None are auto-migrated.

- **Docker image `claude-pal:latest`** — orphaned. `/pal-setup` rebuilds as `sandbox-pal:latest` on next run. No user action needed beyond that.
- **Docker volume `claude-pal-claude`** (holds `~/.claude/.credentials.json`, populated by `claude /login` inside the container) — the new workspace uses `sandbox-pal-claude`, which starts empty. Users either re-run `claude /login` inside the new workspace, or copy: `docker run --rm -v claude-pal-claude:/src -v sandbox-pal-claude:/dst alpine cp -a /src/. /dst/`.
- **Host config `~/.config/claude-pal/config.env`** — copy with `cp -r ~/.config/claude-pal ~/.config/sandbox-pal` (or re-create).

CHANGELOG entry documents these three steps verbatim. No migration script; copy-pasteable commands are enough for the expected user count.

## Implementation approach

Single PR on branch `rename-to-sandbox-pal`:

1. Mechanical substitution of `claude-pal` → `sandbox-pal` in code, docs, tests, fixtures, leaving the exceptions above intact. Exceptions are enumerated; a grep pass after substitution confirms only those remain.
2. `git mv` the three `docs/superpowers/*claude-pal*.md` files to their renamed paths so history follows.
3. `.claude-plugin/marketplace.json`: `source.ref` → `"main"`.
4. CHANGELOG: add a new `## [Unreleased]` section above `## [0.5.0]` documenting the rename, the three migration steps, and the unchanged `pal-*` surface. The repo has not used an Unreleased section before; this introduces the convention. Promoted to a dated version header when the next release cuts.
5. Verify: `shellcheck $(find . -name '*.sh')` clean, `bats tests/` green, `claude plugin validate ~/repos/claude-pal` passes on the renamed manifests, `claude --plugin-dir ~/repos/claude-pal` loads the plugin and a `pal-*` skill fires successfully.
6. Merge PR. User then performs GitHub-side rename + local remote update per the procedure above.

## Testing

- **Shellcheck**: zero warnings across all `.sh` files.
- **BATS**: full suite green. Tests that assert specific image tags (`test_image.bats`, `test_image_smoke.bats`), volume names (`test_workspace_lifecycle.bats`), or container names will be updated to reference the new identifiers.
- **Fake-docker shim**: `tests/test_helper/fake-docker.sh` expectations updated for the new image/volume names.
- **Plugin validation**: `claude plugin validate ~/repos/claude-pal` passes (name, repo, manifest schema consistent).
- **Runtime smoke**: `claude --plugin-dir ~/repos/claude-pal` loads; `/pal-setup` builds `sandbox-pal:latest`; at least one `pal-*` skill fires end-to-end against `sandbox-pal-workspace`.
- **Grep sanity**: post-substitution, `grep -r claude-pal` returns only the documented exceptions (sibling repo ref, PAT filename, historical CHANGELOG entries predating this change).
