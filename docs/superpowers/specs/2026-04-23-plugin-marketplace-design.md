# claude-pal Plugin Marketplace — Design

**Status:** Approved 2026-04-23
**Issue:** [#19 — Distribute claude-pal via self-hosted GitHub plugin marketplace](https://github.com/jnurre64/claude-pal/issues/19)
**Supersedes:** —

## Goal

Make `jnurre64/claude-pal` a self-hosted Claude Code plugin marketplace so end-users can install claude-pal with a one-time `/plugin marketplace add jnurre64/claude-pal` + `/plugin install claude-pal@claude-pal`, replacing the session-scoped `claude --plugin-dir ~/repos/claude-pal` flow.

Users never need to clone the repo. The plugin persists across Claude Code sessions. Updates arrive when we cut a new release and bump the manifest's `ref`.

## Non-goals

- Prebuilt container image distribution (tracked in [#18](https://github.com/jnurre64/claude-pal/issues/18)). `/pal-setup` continues to build the image on first run.
- CI automation for `marketplace.json` `ref` bumping. Manual for v1; can be added later.
- Multi-plugin repo layout. The flat, single-plugin layout is intentional — revisit only if a second plugin is added to the repo.
- Version bump itself. Whether/when to cut `v0.5.0` (or `v0.6.0`, etc.) is out of scope for this issue; the release runbook below describes the mechanical step but does not prescribe the number.

## Architecture

Self-hosted marketplace: the `jnurre64/claude-pal` repo hosts both the plugin *and* its `marketplace.json`.

**Layout — flat.** The repo already uses `.claude-plugin/plugin.json` at its existing location. The marketplace manifest joins it as `.claude-plugin/marketplace.json`, with the plugin entry's `source` set to `"./"` (the repo root, which is where `plugin.json` lives).

**Rationale.** Flat is the prevailing convention when a repo hosts exactly one plugin (e.g. `obra/superpowers`). Nested `plugins/<name>/` layouts (e.g. `anthropics/claude-code`) only exist because those repos host multiple plugins. Adopting nesting preemptively would add path indirection without benefit.

**Distribution path.** `/plugin marketplace add jnurre64/claude-pal` — Claude Code clones into a managed cache at `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. `${CLAUDE_PLUGIN_ROOT}` resolves from the cached copy, so the repo's existing `lib/` sourcing pattern (`. "${CLAUDE_PLUGIN_ROOT}/lib/*.sh"`) keeps working unchanged.

**Security model.** Trust-on-first-use, no signature verification — same as every GitHub-hosted marketplace. Public repo, so no `GH_TOKEN` bootstrap problem.

## marketplace.json

```json
{
  "name": "claude-pal",
  "owner": { "name": "jnurre64" },
  "plugins": [
    {
      "name": "claude-pal",
      "source": "./",
      "description": "Local agent dispatch for Claude Code — publishes implementation plans to GitHub and runs a gated pipeline (adversarial plan review → TDD implement → post-impl review → PR) inside a long-running Docker workspace container.",
      "homepage": "https://github.com/jnurre64/claude-pal",
      "category": "automation",
      "ref": "v<next>"
    }
  ]
}
```

**Field notes:**
- `description` mirrors `plugin.json`'s `description` (updated here to reflect the current workspace-container model, which the stale `plugin.json` description does not fully capture).
- `homepage` and `category` are cheap metadata that improve the `/plugin` listing UX.
- `icon` is intentionally omitted — binary-path handling adds friction we don't need today.
- `ref` is a literal tag name (e.g. `"v0.5.0"`). Filled in at release time (see runbook).

## Update model

**Model A: pin to latest release tag, bump manifest per release.** Chosen over the alternatives considered in issue #19:

- **(A) Pin `ref` to tag — chosen.** Dominant real-world pattern. Users get predictable updates only when a release is cut. Requires bumping `marketplace.json`'s `ref` on each release. Manual for v1.
- **(B) Track `main`.** Simpler for us, less predictable for users (updates arrive whenever a merge lands). Rejected.
- **(C) Two entries — stable tag + `dev` on `main`.** Best UX, most maintenance overhead. Overkill at current scale.

`/plugin marketplace update` re-reads the marketplace manifest. Because our entries are `ref`-pinned to a tag, installed plugins move only when the manifest's `ref` changes — i.e., on release.

## Release sequencing

**Option A: one PR, tag after merge.**

1. Feature branch: add `.claude-plugin/marketplace.json`, rewrite docs, commit.
2. Final commit on the branch bumps:
   - `plugin.json` `version` → target release version.
   - `marketplace.json` `plugins[0].ref` → target tag name (e.g. `"v0.5.0"`).
3. Merge PR into `main`.
4. Tag the merge commit with the target version: `git tag v<next> <merge-sha> && git push origin v<next>`.
5. Create a GitHub release from the tag (optional but recommended for changelog visibility).

There is a seconds-long window between PR merge and tag push where `main`'s `marketplace.json` references an unpushed tag. If a user adds the marketplace during that window they'll see a resolution failure. Acceptable; mitigated by keeping the tag push immediately after the merge.

Rejected alternative: a two-phase approach (land marketplace.json first with `ref: "v0.4.0"` as a placeholder, cut the real tag later) was considered and rejected. `v0.4.0` predates the workspace-container rework and would give any interim installer a broken build.

## Documentation updates

### `docs/install.md`

Current file leads with `git clone` + `claude --plugin-dir ~/repos/claude-pal`. Rewrite so **"Install steps"** becomes:

1. **Install the Claude Code plugin** — the new marketplace recipe:
   ```
   /plugin marketplace add jnurre64/claude-pal
   /plugin install claude-pal@claude-pal
   ```
2. Build (or pull) the container image — unchanged content, but revisit the example path since `./scripts/build-image.sh` assumes a clone. The implementation plan will decide between (a) running the script from its cached plugin location, (b) folding the build into `/pal-setup`, or (c) keeping the clone step as a prerequisite for image build only. This spec does not prescribe the choice — it's a secondary docs decision that should not block the marketplace work.
3. Export `GH_TOKEN` — unchanged.
4. `/pal-setup` then `/pal-login` — unchanged.

A new **"Contributor / local dev loop"** section at the end of the file retains the existing `claude plugin validate ~/repos/claude-pal` + `claude --plugin-dir ~/repos/claude-pal` content, for maintainers and PR contributors.

### `README.md`

Two sections need touch-ups:

- **`Getting started`** currently points at `docs/install.md` — keep that pointer but add a one-line install snippet above it:
  ```
  /plugin marketplace add jnurre64/claude-pal
  /plugin install claude-pal@claude-pal
  ```
- **`One-time setup`** currently opens with `docker pull claude-pal:latest`. Prepend the marketplace install as step 0 so the ordering becomes: add marketplace → pull/build image → `/pal-setup` → `/pal-login`.

### Release runbook

A short **"Releasing"** section in this spec (below) captures the release mechanics. No separate `RELEASING.md`. If the runbook grows past what fits in a spec, split it later.

## Smoke test (manual, pre-tag)

Run on a clean Claude Code config before pushing the release tag:

```bash
CLAUDE_CONFIG_DIR=$(mktemp -d) claude
```

Inside the session:

1. `/plugin marketplace add jnurre64/claude-pal` — confirm no errors.
2. `/plugin install claude-pal@claude-pal` — confirm install succeeds.
3. `/plugin` — confirm `claude-pal` appears in the listed plugins.
4. `/skills` — confirm `pal-*` skills are present.
5. `/claude-pal:pal-setup` — confirm the workspace container boots and credentials can be minted.

Not wired into CI. Automation of this loop is deferred.

## Releasing (runbook)

Once per release:

1. Update `CHANGELOG.md` with the version's entry.
2. Edit `.claude-plugin/plugin.json` — bump `version`.
3. Edit `.claude-plugin/marketplace.json` — set `plugins[0].ref` to the new tag name (e.g. `"v0.5.0"`).
4. Commit: `chore(release): v<next>`.
5. Open PR, merge to `main`.
6. Tag the merge commit: `git tag v<next> <sha> && git push origin v<next>`.
7. Optional: `gh release create v<next> --notes-from-tag` or write release notes by hand.
8. Run the smoke test against the freshly-tagged release.

Steps 2 and 3 must stay in lockstep: if `plugin.json` claims a version the marketplace manifest doesn't point at, `/plugin marketplace update` won't pick up the change cleanly.

## Pitfalls

- **Cache-only resolution.** Files outside the plugin root (i.e. outside the directory named by `source`) don't make it into the Claude Code cache. The claude-pal repo keeps all runtime files under the root already, but the spec mandates a grep sweep for any `../` references before release (verified clean at spec time — only hits are in vendored bats test fixtures under `tests/bats/`, which aren't in the runtime path).
- **Private repos.** Not applicable to this repo (public), but note in docs that any user who forks to private would need `GH_TOKEN` set for `/plugin marketplace add` to succeed.
- **User-global state.** The marketplace list lives in `~/.claude/plugins/known_marketplaces.json`, not per-project — all Claude Code sessions on a host share it. Users uninstall via `/plugin marketplace remove claude-pal`. Worth one line in docs.

## Test plan

**Unit / CI:** none new. `shellcheck` and BATS-Core continue to cover the existing shell surface. `marketplace.json` is a static JSON file — a `jq . .claude-plugin/marketplace.json` check can slot into CI as a cheap parse-validity guard if desired (included in the implementation plan as a nice-to-have).

**Manual pre-release:** the smoke test recipe in the "Smoke test" section above.

**Manual post-release:** on another clean host, repeat `/plugin marketplace add jnurre64/claude-pal` to confirm the published tag resolves.

## Open questions

None. The two open questions raised in issue #19 have been resolved:

- *Automate `marketplace.json` ref bumping?* → Manual for v1.
- *Tag `v0.5.0` now?* → Out of scope; the version bump happens at release time and is not prescribed by this spec.

## Sources

- [Plugin marketplaces — code.claude.com](https://code.claude.com/docs/en/plugin-marketplaces)
- [Discover and install plugins — code.claude.com](https://code.claude.com/docs/en/discover-plugins)
- [Plugins reference — code.claude.com](https://code.claude.com/docs/en/plugins-reference)
- [`obra/superpowers-marketplace`](https://github.com/obra/superpowers-marketplace)
- [`anthropics/claude-code` marketplace.json](https://github.com/anthropics/claude-code/blob/main/.claude-plugin/marketplace.json)
