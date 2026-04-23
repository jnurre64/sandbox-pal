# Plugin Marketplace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish claude-pal as a self-hosted Claude Code plugin marketplace at `jnurre64/claude-pal` so end-users install it with `/plugin marketplace add jnurre64/claude-pal` + `/plugin install claude-pal@claude-pal` instead of cloning and using session-scoped `--plugin-dir`.

**Architecture:** Add `.claude-plugin/marketplace.json` next to the existing `plugin.json` with a single flat plugin entry (`source: "./"`). Move the image-build step out of the user-facing docs and into `/pal-setup` so the marketplace install flow does not require a repo clone. Contributor clone-and-`--plugin-dir` workflow stays, documented separately. Release follows Model A: pin `marketplace.json` `ref` to the latest tag and bump per release.

**Tech Stack:** Bash + shellcheck + BATS-Core (existing test toolchain), Docker (for image-build path), `jq` (for CI JSON validation), Claude Code plugin manifest schema.

**Spec:** `docs/superpowers/specs/2026-04-23-plugin-marketplace-design.md`
**Issue:** [#19](https://github.com/jnurre64/claude-pal/issues/19)

---

## File Structure

**Create:**
- `.claude-plugin/marketplace.json` — marketplace manifest (flat, single plugin entry)
- `lib/image.sh` — image presence-check and build logic, sourced by `/pal-setup`
- `tests/test_image.bats` — BATS tests for `lib/image.sh` using the `fake-docker.sh` shim

**Modify:**
- `commands/pal-setup.md` — incorporate the image-ensure step (replacing the `docker pull claude-pal:latest (or build locally from image/)` guidance)
- `docs/install.md` — rewrite "Install steps" for marketplace flow; move clone-based workflow into a "Contributor / local dev loop" section at the end
- `README.md` — update "Getting started" one-liner and the "One-time setup" block
- `tests/test_helper/fake-docker.sh` — extend the shim to distinguish `docker image inspect` from container `inspect`, and to record `docker build` calls
- `.github/workflows/ci.yml` — add a cheap `jq` parse-check for `.claude-plugin/marketplace.json`

**Not touched in this plan:**
- `.claude-plugin/plugin.json` — its `version` field will bump in the final release task (separate commit), not during feature work
- `scripts/build-image.sh` — kept as the contributor / CI entry point; unchanged
- `image/Dockerfile` — no changes

---

## Task 1: Extend `fake-docker.sh` to support `docker image inspect` and record `docker build`

The existing shim routes everything whose first arg is `inspect` through container-inspect semantics and silently succeeds on `docker build`. The new `pal_image_exists` / `pal_image_build` functions need distinct observables: image-exists state separate from container-exists state, and a way for tests to assert `docker build` was invoked with the right flags.

**Files:**
- Modify: `tests/test_helper/fake-docker.sh`

- [ ] **Step 1: Read the current shim structure**

Re-read `tests/test_helper/fake-docker.sh` lines 14-70 to confirm the `case "$1" in` layout before editing. The key insight: `docker image inspect foo:latest` has `$1 == "image"`, so it needs a new top-level case branch (not a nested match under `inspect`).

- [ ] **Step 2: Write the failing test (anchor for the new shim behavior)**

Add a new file `tests/test_fake_docker_shim.bats` with:

```bash
#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() { fake_docker_setup; }
teardown() { fake_docker_teardown; }

@test "fake docker: 'image inspect' fails when image not registered" {
    run docker image inspect claude-pal:latest
    assert_failure
}

@test "fake docker: 'image inspect' succeeds after fake_docker_set_image_exists" {
    fake_docker_set_image_exists claude-pal:latest
    run docker image inspect claude-pal:latest
    assert_success
}

@test "fake docker: 'build' is recorded in FAKE_DOCKER_LOG" {
    run docker build -t claude-pal:latest -f some/Dockerfile .
    assert_success
    run grep -F "build -t claude-pal:latest" "$FAKE_DOCKER_LOG"
    assert_success
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
./tests/bats/bin/bats tests/test_fake_docker_shim.bats
```

Expected: all three tests FAIL — `image inspect` currently succeeds unconditionally (routed through the generic `*)` branch), `fake_docker_set_image_exists` is undefined, and `build` is recorded (because of the top-of-shim `echo "$*" >> LOG`) so that third test may already pass; confirm which tests fail before moving on.

- [ ] **Step 4: Update the shim to add `image` handling**

In `tests/test_helper/fake-docker.sh`, inside the `case "$1" in` block (between `inspect)` and `exec)`), add:

```bash
    image)
        # Handle `docker image inspect <tag>` — success only if the tag is
        # marked present via fake_docker_set_image_exists.
        if [ "${2:-}" = "inspect" ] && [ -n "${3:-}" ]; then
            if [ -f "$FAKE_DOCKER_STATE/image_${3//:/_}" ]; then
                echo '[{"Id":"fake"}]'
                exit 0
            fi
            exit 1
        fi
        # Any other `docker image <subcommand>` — default success.
        ;;
    build)
        # Already logged at top of shim; default success. Tests grep the log.
        ;;
```

The `${3//:/_}` swap maps `claude-pal:latest` to `claude-pal_latest` — a legal filename. The `image_` prefix keeps image-presence markers distinct from `exists` / `running` container markers used elsewhere in the shim. Keep the existing `echo "$*" >> "$FAKE_DOCKER_LOG"` at the top of the shim — it already captures every invocation including `build`.

- [ ] **Step 5: Add the `fake_docker_set_image_exists` / `fake_docker_set_image_absent` helpers**

After the existing `fake_docker_set_absent` function in the shim, add:

```bash
fake_docker_set_image_exists() {
    local tag="${1:-claude-pal:latest}"
    : > "$FAKE_DOCKER_STATE/image_${tag//:/_}"
}

fake_docker_set_image_absent() {
    local tag="${1:-claude-pal:latest}"
    rm -f "$FAKE_DOCKER_STATE/image_${tag//:/_}"
}
```

- [ ] **Step 6: Run the tests and confirm they pass**

```bash
./tests/bats/bin/bats tests/test_fake_docker_shim.bats
```

Expected: all three PASS.

- [ ] **Step 7: Run the full bats suite to catch regressions**

```bash
./tests/bats/bin/bats tests/
```

Expected: all existing tests still pass (the new `image` / `build` case arms don't intersect container-inspect behavior, which other tests rely on).

- [ ] **Step 8: Commit**

```bash
git add tests/test_helper/fake-docker.sh tests/test_fake_docker_shim.bats
git commit -m "test(fake-docker): add image-inspect and build-call observables"
```

---

## Task 2: Implement `pal_image_exists` in `lib/image.sh`

Thin wrapper over `docker image inspect`. This is what `pal_image_ensure` (Task 4) will call to decide whether to build.

**Files:**
- Create: `lib/image.sh`
- Create: `tests/test_image.bats`

- [ ] **Step 1: Create the test file with a failing test**

Create `tests/test_image.bats`:

```bash
#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    fake_docker_setup
    # shellcheck source=../lib/image.sh
    . "$REPO_ROOT/lib/image.sh"
}

teardown() {
    fake_docker_teardown
}

@test "pal_image_exists: returns success when image is present" {
    fake_docker_set_image_exists claude-pal:latest
    run pal_image_exists
    assert_success
}

@test "pal_image_exists: returns failure when image is absent" {
    fake_docker_set_image_absent claude-pal:latest
    run pal_image_exists
    assert_failure
}

@test "pal_image_exists: uses PAL_WORKSPACE_IMAGE override" {
    fake_docker_set_image_exists claude-pal:v0.5.0
    PAL_WORKSPACE_IMAGE=claude-pal:v0.5.0 run pal_image_exists
    assert_success
}
```

- [ ] **Step 2: Run the test — it must fail because `lib/image.sh` does not exist yet**

```bash
./tests/bats/bin/bats tests/test_image.bats
```

Expected: all three tests FAIL — bats reports that `lib/image.sh` cannot be sourced (no such file).

- [ ] **Step 3: Create `lib/image.sh` with the minimal function**

```bash
# lib/image.sh
# shellcheck shell=bash
# Host-side helpers for the claude-pal container image.

: "${PAL_WORKSPACE_IMAGE:=claude-pal:latest}"

pal_image_exists() {
    docker image inspect "$PAL_WORKSPACE_IMAGE" >/dev/null 2>&1
}
```

The `PAL_WORKSPACE_IMAGE` default matches `lib/workspace.sh`'s default exactly so the two files agree on which image the workspace expects.

- [ ] **Step 4: Run the test again — confirm all three pass**

```bash
./tests/bats/bin/bats tests/test_image.bats
```

Expected: all three PASS.

- [ ] **Step 5: Run shellcheck**

```bash
shellcheck lib/image.sh
```

Expected: zero warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/image.sh tests/test_image.bats
git commit -m "feat(lib): add pal_image_exists check for claude-pal:latest"
```

---

## Task 3: Implement `pal_image_build` in `lib/image.sh`

Runs `docker build` against the plugin-root Dockerfile. The function does not prompt — it builds unconditionally; the calling skill (Task 5) is responsible for asking the user first.

**Files:**
- Modify: `lib/image.sh`
- Modify: `tests/test_image.bats`

- [ ] **Step 1: Add the failing test**

Append to `tests/test_image.bats`:

```bash
@test "pal_image_build: invokes docker build with Dockerfile and plugin root as context" {
    run pal_image_build
    assert_success
    run grep -F -- "-f ${CLAUDE_PLUGIN_ROOT}/image/Dockerfile" "$FAKE_DOCKER_LOG"
    assert_success
    run grep -F -- "-t claude-pal:latest" "$FAKE_DOCKER_LOG"
    assert_success
    # Build context is the plugin root (trailing positional).
    run grep -F -- "${CLAUDE_PLUGIN_ROOT}" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_build: passes BASE_IMAGE build-arg (default ubuntu:24.04)" {
    run pal_image_build
    assert_success
    run grep -F -- "--build-arg BASE_IMAGE=ubuntu:24.04" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_build: respects BASE_IMAGE env override" {
    BASE_IMAGE=ubuntu:22.04 run pal_image_build
    assert_success
    run grep -F -- "--build-arg BASE_IMAGE=ubuntu:22.04" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_build: respects PAL_WORKSPACE_IMAGE tag override" {
    PAL_WORKSPACE_IMAGE=claude-pal:v0.5.0 run pal_image_build
    assert_success
    run grep -F -- "-t claude-pal:v0.5.0" "$FAKE_DOCKER_LOG"
    assert_success
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./tests/bats/bin/bats tests/test_image.bats
```

Expected: the four new tests FAIL — `pal_image_build` is undefined.

- [ ] **Step 3: Implement `pal_image_build` in `lib/image.sh`**

Append to `lib/image.sh`:

```bash
pal_image_build() {
    local base_image="${BASE_IMAGE:-ubuntu:24.04}"
    docker build \
        --build-arg BASE_IMAGE="$base_image" \
        -f "${CLAUDE_PLUGIN_ROOT}/image/Dockerfile" \
        -t "$PAL_WORKSPACE_IMAGE" \
        "${CLAUDE_PLUGIN_ROOT}"
}
```

This mirrors `scripts/build-image.sh` (which `cd`s into `REPO_ROOT` and runs `docker build -f image/Dockerfile .`) but uses `${CLAUDE_PLUGIN_ROOT}` as the explicit build context so it works identically from a clone or from the marketplace cache.

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
./tests/bats/bin/bats tests/test_image.bats
```

Expected: all seven tests (3 from Task 2 + 4 from Task 3) PASS.

- [ ] **Step 5: Run shellcheck**

```bash
shellcheck lib/image.sh
```

Expected: zero warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/image.sh tests/test_image.bats
git commit -m "feat(lib): add pal_image_build using \${CLAUDE_PLUGIN_ROOT}"
```

---

## Task 4: Implement `pal_image_ensure` in `lib/image.sh`

The compose point: check if the image exists; if not, build it. Single entry point for `/pal-setup`.

**Files:**
- Modify: `lib/image.sh`
- Modify: `tests/test_image.bats`

- [ ] **Step 1: Add the failing test**

Append to `tests/test_image.bats`:

```bash
@test "pal_image_ensure: builds when image is absent" {
    fake_docker_set_image_absent claude-pal:latest
    run pal_image_ensure
    assert_success
    run grep -F "build" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_ensure: does NOT build when image is already present" {
    fake_docker_set_image_exists claude-pal:latest
    run pal_image_ensure
    assert_success
    run grep -F "build" "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "pal_image_ensure: prints progress note when building" {
    fake_docker_set_image_absent claude-pal:latest
    run pal_image_ensure
    assert_success
    assert_output --partial "pal: building claude-pal:latest"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./tests/bats/bin/bats tests/test_image.bats
```

Expected: the three new tests FAIL — `pal_image_ensure` is undefined.

- [ ] **Step 3: Implement `pal_image_ensure` in `lib/image.sh`**

Append to `lib/image.sh`:

```bash
pal_image_ensure() {
    if pal_image_exists; then
        return 0
    fi
    echo "pal: building ${PAL_WORKSPACE_IMAGE}…" >&2
    pal_image_build
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
./tests/bats/bin/bats tests/test_image.bats
```

Expected: all 10 tests in `tests/test_image.bats` PASS.

- [ ] **Step 5: Run shellcheck and the full bats suite**

```bash
shellcheck lib/image.sh
./tests/bats/bin/bats tests/
```

Expected: zero shellcheck warnings; all bats tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/image.sh tests/test_image.bats
git commit -m "feat(lib): add pal_image_ensure (build-if-absent compose point)"
```

---

## Task 5: Wire `pal_image_ensure` into `/pal-setup`

Replace the current step-3 guidance (`docker pull claude-pal:latest (or build locally from image/)`) with a direct call to `pal_image_ensure`. The skill still walks the user through env-var and credentials steps — only the image provisioning changes.

**Files:**
- Modify: `commands/pal-setup.md`

- [ ] **Step 1: Rewrite the skill body**

Replace the entire current body of `commands/pal-setup.md` (keeping the frontmatter untouched) with:

````markdown
# /claude-pal:pal-setup

Guided, one-time setup for claude-pal.

Walk the user through:

1. Verify `docker` is on PATH and reachable (`docker info` succeeds).
2. Verify `GH_TOKEN` (or `GITHUB_TOKEN`) is exported in the shell. If missing,
   instruct:

       echo 'export GH_TOKEN=github_pat_<token>' >> ~/.bashrc
       source ~/.bashrc

   The PAT needs `Contents`, `Pull requests`, `Issues` (read/write) on target repos.
3. Ensure the `claude-pal:latest` image is present. Source the helper and call
   `pal_image_ensure`:

       . "${CLAUDE_PLUGIN_ROOT}/lib/image.sh"
       pal_image_ensure

   - If the image is already present, this is a no-op.
   - If it is absent, `pal_image_ensure` runs `docker build` against
     `${CLAUDE_PLUGIN_ROOT}/image/Dockerfile` with the plugin root as the
     build context (equivalent to `./scripts/build-image.sh` from a clone).
     Before running, tell the user what will happen and wait for confirmation;
     the build takes a few minutes the first time.
   - If the build fails, surface the `docker build` output verbatim — do not
     retry silently.
4. Run `/pal-workspace start` — creates the named volume and the long-running
   workspace container.
5. Run `/pal-login` — mints Claude credentials inside the workspace (one-time
   interactive browser flow). Credentials persist in the `claude-pal-claude`
   named volume; they never touch the host filesystem.
6. (Optional) `/pal-workspace edit-rules` — opens an empty
   `~/.config/claude-pal/container-CLAUDE.md` that will be synced into the
   container on every run. Use it for container-scoped behavior rules.
7. (Optional) create `~/.config/claude-pal/config.env` with non-secret knobs:

       PAL_CPUS=2.0
       PAL_MEMORY=4g
       PAL_SYNC_MEMORIES=true
       PAL_SYNC_TRANSCRIPTS=false

Report back what was verified and what still needs doing.
````

- [ ] **Step 2: Manually verify the markdown renders and the commands are sensible**

```bash
cat commands/pal-setup.md
```

Expected: frontmatter preserved; step 3 references `${CLAUDE_PLUGIN_ROOT}/lib/image.sh` and `pal_image_ensure`; the rest of the steps (4–7) are unchanged from the previous version.

- [ ] **Step 3: Commit**

```bash
git add commands/pal-setup.md
git commit -m "feat(skill): /pal-setup auto-builds image via pal_image_ensure"
```

---

## Task 6: Add `.claude-plugin/marketplace.json`

Ships the marketplace manifest. `ref` is set to `"main"` during development; the final release task (Task 11) flips it to the chosen tag before merge.

**Files:**
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create the manifest**

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
      "ref": "main"
    }
  ]
}
```

- [ ] **Step 2: Verify JSON parses cleanly**

```bash
jq . .claude-plugin/marketplace.json
```

Expected: the manifest echoed back formatted; exit code 0.

- [ ] **Step 3: Validate via Claude Code's plugin validator**

```bash
claude plugin validate .
```

Expected: `✔ Validation passed` (the validator recognises both `plugin.json` and `marketplace.json`). If the validator reports a schema error for `marketplace.json`, that is a real bug — fix before committing.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "feat(plugin): add .claude-plugin/marketplace.json"
```

---

## Task 7: Add `jq` parse check for `marketplace.json` to CI

Cheap guard against a future edit corrupting the JSON. Runs in the existing `bats` job (which already `apt-get`s nothing extra — `jq` is preinstalled on `ubuntu-latest`).

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add a new job to `.github/workflows/ci.yml`**

Insert before the `bats:` job (so it runs in parallel with shellcheck and bats):

```yaml
  marketplace-json:
    name: marketplace.json parses
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Validate .claude-plugin/marketplace.json with jq
        run: jq -e . .claude-plugin/marketplace.json > /dev/null
      - name: Validate .claude-plugin/plugin.json with jq
        run: jq -e . .claude-plugin/plugin.json > /dev/null
```

`jq -e` makes jq exit non-zero if the filter produces a false or null value — here it doubles as a structural sanity check (no accidental `null` document).

- [ ] **Step 2: Run the parse locally to mirror what CI will do**

```bash
jq -e . .claude-plugin/marketplace.json > /dev/null
jq -e . .claude-plugin/plugin.json > /dev/null
echo "exit: $?"
```

Expected: `exit: 0`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add jq parse check for .claude-plugin/*.json"
```

---

## Task 8: Rewrite `docs/install.md` for the marketplace flow

Main install path moves to marketplace install; clone-based workflow becomes the "Contributor / local dev loop" section at the bottom.

**Files:**
- Modify: `docs/install.md`

- [ ] **Step 1: Replace lines 21–124 (the `## Install steps` block) with the new marketplace-first flow**

Replace from `## Install steps` through the end of step 7 ("### 7. First live dispatch …") with:

````markdown
## Install steps

### 1. Export `GH_TOKEN` in your shell profile

claude-pal only needs **one** host env var: `GH_TOKEN`. Claude credentials live inside the workspace container (step 3) — they are never exported from your shell.

Create a fine-grained GitHub PAT at https://github.com/settings/personal-access-tokens. Grant repository access for each repo you plan to dispatch against, with these scopes:

- Contents: read and write
- Pull requests: read and write
- Issues: read and write
- Metadata: read

Append to `~/.bashrc` (or `~/.zshrc`):

```bash
# claude-pal
export GH_TOKEN=github_pat_...your-PAT...
```

Save, then `source ~/.bashrc` in any shell that needs the new value.

**Windows (PowerShell, persistent for the current user):**
```powershell
[System.Environment]::SetEnvironmentVariable('GH_TOKEN', 'github_pat_...', 'User')
# Open a new PowerShell / Git Bash to pick up the new env
```

> **Do not** set `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` in your shell — the workspace-container model does not use them. If you have them set from an earlier claude-pal install, `unset` them and remove them from your rc files. See [`docs/authentication.md`](authentication.md) for the full rationale.

### 2. Install the Claude Code plugin from the marketplace

From any `claude` session:

```
/plugin marketplace add jnurre64/claude-pal
/plugin install claude-pal@claude-pal
```

Claude Code pulls the repo into its plugin cache and persists the install across sessions. Verify:

```
/plugin          # should show claude-pal as loaded
/skills          # should list pal-plan, pal-implement, pal-workspace, pal-login, pal-logout, etc.
```

### 3. Create the workspace, build the image, and log in

In the same session:

```
/claude-pal:pal-setup
```

`pal-setup` verifies Docker + `GH_TOKEN`, then ensures the `claude-pal:latest` image exists. The first time you run it, `pal-setup` will offer to build the image (a few minutes; `docker build` against the Dockerfile inside the cached plugin). Subsequent runs are no-ops for the image step.

```
/claude-pal:pal-login
# → opens a browser to authorize Claude inside the workspace
# → writes /home/agent/.claude/.credentials.json into the `claude-pal-claude` named volume
# → one-time, persists for the workspace's lifetime
```

Verify:

```
/claude-pal:pal-workspace status
```

From the host shell you can inspect the volume:

```bash
docker volume inspect claude-pal-claude
docker exec claude-pal-workspace ls -la /home/agent/.claude/
```

### 4. First live dispatch (validate end-to-end)

```
# From a checkout of a GitHub repo the PAT can access:
/claude-pal:pal-plan
# → publishes the most recent docs/superpowers/plans/*.md file as a new issue
# → prints the issue URL

/claude-pal:pal-implement <the-issue-number>
# → runs preflight checks
# → docker execs the pipeline inside the workspace (adversarial review → TDD → post-impl review → PR)
# → prints the PR URL on success
```

Watch for errors at each stage. Common failures are covered below.
````

- [ ] **Step 2: Append the "Contributor / local dev loop" section to the bottom of `docs/install.md`**

After the existing "What's not in this release" section (or at the very end of the file if you prefer), add:

````markdown
## Contributor / local dev loop

If you're developing against a clone of the repo (sending PRs, iterating on skills), the marketplace install is not what you want — use the session-scoped `--plugin-dir` instead so you can edit files and see changes immediately.

```bash
# Clone
git clone https://github.com/jnurre64/claude-pal.git ~/repos/claude-pal
cd ~/repos/claude-pal

# Validate the manifest (fast, no session needed)
claude plugin validate ~/repos/claude-pal
# → "✔ Validation passed"

# Build the image directly (the marketplace flow does this via /pal-setup;
# contributors often want to iterate on the Dockerfile without going through
# the skill each time)
./scripts/build-image.sh

# Load the plugin for one session
claude --plugin-dir ~/repos/claude-pal
```

`--plugin-dir` is scoped to that single `claude` session. Contributors typically have the marketplace install removed (`/plugin marketplace remove claude-pal`) while iterating, to avoid two loaded copies of the plugin fighting over skill names.
````

- [ ] **Step 3: Proofread the file**

```bash
less docs/install.md
```

Check: step numbering runs 1 → 4 (not 1-2-then-4), all internal links resolve, the troubleshooting table mentions `/claude-pal:pal-workspace` not the old clone path, and the contributor section appears at the end.

- [ ] **Step 4: Commit**

```bash
git add docs/install.md
git commit -m "docs(install): marketplace-first install flow; clone moved to contributor section"
```

---

## Task 9: Update `README.md` "Getting started" and "One-time setup"

Align the README with the install.md rewrite. Two blocks change; everything else (What it does, Authentication intro, Per-repo config, Plugin skills, Contributing, License) stays.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the "Getting started" section**

Replace the block at lines 31–33:

```markdown
## Getting started

See [`docs/install.md`](docs/install.md).
```

with:

```markdown
## Getting started

```
/plugin marketplace add jnurre64/claude-pal
/plugin install claude-pal@claude-pal
/claude-pal:pal-setup
/claude-pal:pal-login
```

Full walkthrough in [`docs/install.md`](docs/install.md).
```

- [ ] **Step 2: Replace the "One-time setup" block**

Replace the block at lines 47–59 (the `### One-time setup` fenced block):

```markdown
### One-time setup

```bash
# 1. GitHub PAT (fine-grained, Contents + Pull requests + Issues read/write)
export GH_TOKEN=github_pat_<token>   # add to ~/.bashrc or ~/.zshrc

# 2. Pull (or build) the image
docker pull claude-pal:latest

# 3. Start the workspace and mint Claude credentials
/pal-setup     # creates the named volume + workspace container
/pal-login     # interactive browser flow, run once per workspace lifetime
```
```

with:

````markdown
### One-time setup

1. Export `GH_TOKEN` in your shell (add to `~/.bashrc` or `~/.zshrc`):
   ```bash
   export GH_TOKEN=github_pat_<token>
   ```
2. Install the plugin from the marketplace (from any `claude` session):
   ```
   /plugin marketplace add jnurre64/claude-pal
   /plugin install claude-pal@claude-pal
   ```
3. Provision the workspace and credentials:
   ```
   /claude-pal:pal-setup     # builds the image if absent; creates the workspace
   /claude-pal:pal-login     # interactive browser flow, run once per workspace lifetime
   ```
````

- [ ] **Step 3: Proofread**

```bash
less README.md
```

Check: both the Getting started block and the One-time setup block reference the marketplace install path; no mention of `docker pull claude-pal:latest` remains in the user-facing flow (it's fine if it survives anywhere else as a historical note — but the One-time setup should not prescribe it).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): align Getting started + One-time setup with marketplace flow"
```

---

## Task 10: Pre-merge local verification

Marketplace install (`/plugin marketplace add jnurre64/claude-pal`) can only be tested *after* the PR merges into `main` — until then the manifest isn't at the URL Claude Code fetches. So this task is the pre-merge gate: manifest validity, full test suite, and (optionally) an end-to-end `/pal-setup` run against a clone via `--plugin-dir`.

**Files:** none changed; verification only.

- [ ] **Step 1: Validate both plugin manifests**

```bash
jq -e . .claude-plugin/plugin.json > /dev/null
jq -e . .claude-plugin/marketplace.json > /dev/null
claude plugin validate .
```

Expected: all three succeed; `claude plugin validate` reports `✔ Validation passed`.

- [ ] **Step 2: Run shellcheck and the full bats suite**

```bash
shellcheck $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*')
./tests/bats/bin/bats tests/
```

Expected: zero shellcheck warnings; every bats test passes (including the new `tests/test_image.bats` and `tests/test_fake_docker_shim.bats`).

- [ ] **Step 3: (Optional) End-to-end `/pal-setup` via `--plugin-dir`**

If you have the spare ~5 minutes for a real `docker build`, exercise the new `/pal-setup` path against a clone:

```bash
# From a fresh shell (no pre-existing claude-pal:latest image)
docker rmi claude-pal:latest 2>/dev/null || true
claude --plugin-dir $PWD
```

Inside the session: `/claude-pal:pal-setup`. Expect the skill to announce the image is missing, offer to build, and on confirmation run `docker build` against `${CLAUDE_PLUGIN_ROOT}/image/Dockerfile`. Follow through to `/pal-login` + `/pal-workspace status` if you want full end-to-end coverage.

This is optional because the unit tests in `tests/test_image.bats` already cover the decision logic; the real build just catches environment issues (Docker daemon, buildx quirks) that mocks can't.

- [ ] **Step 4: Push the branch and open the PR**

```bash
git push -u origin local-plugin-marketplace
GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token) gh pr create \
  --repo jnurre64/claude-pal \
  --title "Distribute claude-pal via self-hosted plugin marketplace" \
  --body "Closes #19.

Spec: \`docs/superpowers/specs/2026-04-23-plugin-marketplace-design.md\`
Plan: \`docs/superpowers/plans/2026-04-23-plugin-marketplace.md\`

## Summary
- Add \`.claude-plugin/marketplace.json\` (flat layout, single plugin entry).
- \`/pal-setup\` auto-builds \`claude-pal:latest\` via new \`lib/image.sh\` helpers (test coverage in \`tests/test_image.bats\`).
- Rewrite \`docs/install.md\` and \`README.md\` for the marketplace flow; clone-based workflow moves to a contributor section.
- CI \`jq\` parse check for both plugin manifests.

## Test plan
- [x] BATS: \`tests/test_image.bats\`, \`tests/test_fake_docker_shim.bats\`
- [x] shellcheck: clean
- [x] \`claude plugin validate .\`
- [ ] Post-merge smoke test on clean \`CLAUDE_CONFIG_DIR\` (Task 12)
- [ ] Post-tag re-smoke (Task 12)"
```

Leave the PR open for review. The release commit (Task 11) lands on this same branch before merge.

---

## Task 11: Release commit — bump `plugin.json.version` and set `marketplace.json.ref`

This is the final commit on the feature branch before the PR merges. Version number is picked at this point (per the spec, the number itself is out of scope for issue #19 — just the mechanical step is prescribed).

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Pick the target version**

Decide the tag name. Candidates:
- `v0.5.0` — aligns with `CHANGELOG.md`'s 2026-04-21 entry, which currently claims 0.5.0 shipped but no tag exists.
- `v0.6.0` — treat this PR as the 0.6.0 bump (marketplace is a material feature).

Record the choice in the PR description. The rest of this task uses `<TAG>` as a placeholder — substitute the actual value.

- [ ] **Step 2: Bump `plugin.json.version`**

Edit `.claude-plugin/plugin.json`:

```json
{
  "name": "claude-pal",
  "version": "<TAG-without-leading-v>",
  ...
}
```

- [ ] **Step 3: Set `marketplace.json.plugins[0].ref` to the target tag**

Edit `.claude-plugin/marketplace.json`:

```json
    "ref": "<TAG>"
```

- [ ] **Step 4: Validate both files**

```bash
jq -e . .claude-plugin/plugin.json > /dev/null
jq -e . .claude-plugin/marketplace.json > /dev/null
claude plugin validate .
```

Expected: all three commands succeed; validator reports `✔ Validation passed`.

- [ ] **Step 5: Add a CHANGELOG entry (if the chosen tag isn't already in the file)**

If the tag is `v0.6.0` (or any tag not yet in `CHANGELOG.md`), prepend a new entry at the top of the `Added` / `Changed` sections:

```markdown
## [0.6.0] — <today's date>

### Added
- **Plugin marketplace distribution.** claude-pal can now be installed with
  `/plugin marketplace add jnurre64/claude-pal` + `/plugin install claude-pal@claude-pal`,
  replacing the session-scoped `claude --plugin-dir` recipe.
- `.claude-plugin/marketplace.json` (flat layout, single plugin entry pinned to the release tag).
- `lib/image.sh` with `pal_image_exists` / `pal_image_build` / `pal_image_ensure`.

### Changed
- `/pal-setup` now auto-builds `claude-pal:latest` if absent, using
  `${CLAUDE_PLUGIN_ROOT}/image/Dockerfile`. The marketplace install flow
  no longer requires a repo clone for the image build.
- `docs/install.md` rewritten around the marketplace flow; clone workflow
  moved to a "Contributor / local dev loop" section.
- `README.md` "Getting started" and "One-time setup" rewritten for the
  marketplace install.
```

If the tag is `v0.5.0`, the existing 0.5.0 entry already covers this release cycle — in that case append these bullets to the existing `Added` / `Changed` sections instead of creating a new one. (Ask the maintainer before doing this — adding to a tagged/shipped version is unusual.)

- [ ] **Step 6: Commit the release bundle and push**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md
git commit -m "chore(release): v<TAG> — plugin marketplace distribution (#19)"
git push
```

- [ ] **Step 7: Request review on the PR**

The PR was opened in Task 10 Step 4 and has been accumulating review feedback. This release commit is typically the last before merge. Confirm reviewers are happy; request re-review if needed:

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token) gh pr view --repo jnurre64/claude-pal
```

---

## Task 12: Post-merge — tag the merge commit, smoke-test, push

After the maintainer merges the PR, the single-PR-one-tag flow closes with `git tag + git push`. `marketplace.json` on `main` now references a tag that exists, and end users can `/plugin marketplace update` to receive it.

**Files:** none changed; git operations only.

- [ ] **Step 1: Pull the merged `main`**

```bash
git checkout main
git pull --ff-only origin main
```

- [ ] **Step 2: Verify the merge commit contains the release bundle**

```bash
jq -r '.version' .claude-plugin/plugin.json
jq -r '.plugins[0].ref' .claude-plugin/marketplace.json
```

Expected: the `version` matches `<TAG>` (without `v-`), and the `ref` matches `<TAG>` (with `v-`). If either mismatches, the release commit didn't make it in — investigate before tagging.

- [ ] **Step 3: Tag the merge commit and push**

```bash
git tag <TAG>
git push origin <TAG>
```

This closes the "seconds-long window" the spec warns about — `main`'s `marketplace.json` now references a tag that exists.

- [ ] **Step 4: Create a GitHub release from the tag**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token) gh release create <TAG> \
  --repo jnurre64/claude-pal \
  --title "<TAG> — plugin marketplace distribution" \
  --notes-from-tag
```

(If `--notes-from-tag` is unused because the tag is lightweight, pass `--notes-file CHANGELOG.md` or compose inline notes from the CHANGELOG entry added in Task 11 Step 5.)

- [ ] **Step 5: End-to-end smoke test against the published tag**

On a host with `claude` + `docker` installed, but where claude-pal has never been set up:

```bash
CLAUDE_CONFIG_DIR=$(mktemp -d)
export CLAUDE_CONFIG_DIR
export GH_TOKEN=<a valid fine-grained PAT>
# Optional but recommended for a clean test: remove the image first
docker rmi claude-pal:latest 2>/dev/null || true
claude
```

Inside the session, run each step and verify the expected output:

1. `/plugin marketplace add jnurre64/claude-pal` — expect no errors; "marketplace added".
2. `/plugin install claude-pal@claude-pal` — expect the plugin to resolve to `<TAG>` (not `main`) and install.
3. `/plugin` — expect `claude-pal` in the listed plugins; the version column should match `<TAG-without-leading-v>`.
4. `/skills` — expect `pal-plan`, `pal-implement`, `pal-workspace`, `pal-login`, `pal-logout`, `pal-status`, `pal-logs`, `pal-cancel`, `pal-revise` all listed.
5. `/claude-pal:pal-setup` — expect the skill to announce the image is missing and offer to build. Confirm; watch `docker build` run to completion (a few minutes the first time).
6. `/claude-pal:pal-login` — complete the browser flow.
7. `/claude-pal:pal-workspace status` — expect `workspace: claude-pal-workspace (running)` and `auth: present`.

If any step fails, **do not close issue #19.** Instead: fix the bug on a follow-up branch, re-release with a patch version (e.g. `<TAG>.1`), and re-run this smoke test. The bad tag stays (tags are immutable conventionally); users can bypass by reinstalling or running `/plugin marketplace update`.

- [ ] **Step 6: Cleanup after smoke test**

```bash
# Inside the smoke-test session or on the host:
docker stop claude-pal-workspace && docker rm claude-pal-workspace
docker volume rm claude-pal-claude
rm -rf "$CLAUDE_CONFIG_DIR"
```

- [ ] **Step 7: Close issue #19 with a comment linking the release**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token) gh issue close 19 \
  --repo jnurre64/claude-pal \
  --comment "Shipped in <TAG>: https://github.com/jnurre64/claude-pal/releases/tag/<TAG>"
```

---

## Acceptance criteria

- `.claude-plugin/marketplace.json` exists at repo root, parses cleanly with `jq`, and is recognised by `claude plugin validate`.
- `lib/image.sh` with three functions (`pal_image_exists`, `pal_image_build`, `pal_image_ensure`) passes shellcheck and has BATS coverage for: image-present short-circuit, image-absent build path, `BASE_IMAGE` override, `PAL_WORKSPACE_IMAGE` override.
- `commands/pal-setup.md` references `${CLAUDE_PLUGIN_ROOT}/lib/image.sh` and documents the auto-build behavior.
- `docs/install.md` primary flow starts with `/plugin marketplace add` (no `git clone` step in the main path); a Contributor section at the end preserves the clone workflow.
- `README.md` "Getting started" and "One-time setup" both reference the marketplace install.
- CI (`.github/workflows/ci.yml`) runs `jq -e` against both manifest files on every push / PR.
- Post-merge marketplace smoke test (Task 12 Step 5) passes on a clean `CLAUDE_CONFIG_DIR`: `/plugin marketplace add` → `/plugin install` → `/pal-setup` → `/pal-login` → `/pal-workspace status` all succeed.
- `https://github.com/jnurre64/claude-pal/releases/tag/<TAG>` exists and issue #19 is closed with a link to the release.

---

## Non-goals (do not add these tasks)

- **Prebuilt container image publication to GHCR.** Tracked in #18.
- **CI automation of `marketplace.json` `ref` bumping.** Manual for v1 per the spec.
- **Icon in the marketplace entry.** Requires binary-path decisions out of scope here.
- **Changing the repo layout from flat to nested.** Revisit only if a second plugin is ever added.
- **Publishing to the `claude-plugins-official` marketplace.** Separate effort; not part of the self-hosted marketplace work.
