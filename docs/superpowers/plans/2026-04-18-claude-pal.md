# claude-pal v1 Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` with **one Claude Code session per phase**. Each phase ends with a testable milestone that acts as a review checkpoint. Within phases where tasks are independent, `superpowers:dispatching-parallel-agents` can fan out to subagents — see "Execution strategy" below. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1 of `claude-pal` — a Claude Code skill set + Docker container that publishes implementation plans to GitHub issues and runs a gated pipeline (adversarial plan review → TDD implementation → post-impl review → retry → PR) inside an ephemeral Linux container.

**Architecture:** Host-side Claude Code skills (bash, Git Bash on Windows) read a user-owned `config.env`, run preflight checks, and invoke `docker run` against a purpose-built Ubuntu image. The container runs a bash entrypoint that orchestrates 3–5 `claude -p` calls (different tool allowlists per phase) with the review-gate prompts vendored from `jnurre64/claude-agent-dispatch`. Communication between host and container is one-directional: host → container via env vars + bind-mounted `/status` directory; container → host via `/status/status.json` and `/status/log`. Async mode adds a forked watcher that fires a desktop notification on container exit.

**Host-side layout is a Claude Code plugin.** The host-side skills ship as a single plugin with the canonical layout documented in the official `plugin-dev/plugin-structure` skill: a `.claude-plugin/plugin.json` manifest at the plugin root, `skills/<skill-name>/SKILL.md` for each skill, and shared bash helpers under plugin-root `lib/` (not `skills/lib/`). SKILL.md files resolve helpers via the `${CLAUDE_PLUGIN_ROOT}` env var that Claude Code sets when a skill fires — e.g. `. "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"`. This is the pattern used by the official `plugin-dev` plugin and `superpowers` itself; see `references/component-patterns.md` in the official `plugin-dev` skill for the "Shared Resources" example.

**Tech Stack:** Bash 5+, Docker 20+ (Linux containers mode), Claude Code CLI (headless `claude -p`), GitHub CLI (`gh`), `jq`, BATS-Core for testing, Ubuntu 24.04 base image, `notify-send` / `osascript` / BurntToast for cross-platform notifications.

**Repo location:** The `claude-pal` repo lives at `~/repos/claude-pal/` (under the host's existing `~/repos/` directory alongside other project checkouts). Phase 1 Task 1.1 originally created it at `~/claude-pal/`; that was moved to `~/repos/claude-pal/` during Phase 1 execution. All path references in this plan have been updated to the canonical `~/repos/claude-pal/`. The plan itself now lives at `docs/superpowers/plans/2026-04-18-claude-pal.md` inside that repo.

**Spec:** See `docs/superpowers/specs/2026-04-18-claude-pal-design.md` in this repo for the full design document. All design decisions referenced below are justified there.

---

## Phase overview

Each phase ends with a testable milestone. Phases must complete in order (later phases depend on earlier), but within a phase some tasks can parallelize.

| Phase | Milestone |
|---|---|
| 1. Repo scaffold + base image | `docker build` produces a runnable image with claude CLI + prompts vendored |
| 2. Container pipeline | `docker run` end-to-end executes a gated implement pipeline against a test issue |
| 3. `/pal-implement` (sync) | Skill launches the container, streams logs, reports outcome |
| 4. `/pal-plan` | Skill publishes plan from conversation file to issue comment |
| 5. Async mode + run registry + `/pal-status`, `/pal-logs`, `/pal-cancel` | Background runs with desktop notification; run management |
| 6. `/pal-revise` | Skill launches container to address PR review feedback |
| 7. Cross-platform hardening | macOS Keychain, Windows Credential Manager, NTFS ACL check, Git Bash preflight, `pass` opt-in |
| 8. Documentation + release prep | Install guides, config examples, UPSTREAM drift check, v1.0.0 tag |

---

## Execution strategy

**One Claude Code session per phase.** Each phase ends with a testable milestone (image builds, `docker run` round-trips, smoke test passes). Use `superpowers:executing-plans` to execute a single phase per fresh session. Do not start the next phase until:

1. All tasks in the current phase are committed.
2. The phase's milestone has been verified (bats test passes, smoke test round-trips, etc.).
3. The user has reviewed the diff and approved continuing.

This keeps each session's context focused, preserves a natural review checkpoint between phases, and lets a phase be resumed days later without losing context.

**Subagent fan-out inside parallelizable phases.** Inside a single phase session, `superpowers:dispatching-parallel-agents` can dispatch independent tasks concurrently. Phases where this helps:

- **Phase 3** — `config.sh`, `preflight.sh`, `runs.sh`, `launcher.sh` are independent lib files with no shared edits.
- **Phase 5** — `notify.sh`, async launcher wiring, `/pal-status`, `/pal-logs`, `/pal-cancel` are largely independent. Keep the async launcher and `/pal-cancel` sequential since both append to `launcher.sh`.
- **Phase 7** — macOS Keychain, Windows Credential Manager, Linux `pass`, NTFS ACL check — all touch `config.sh` so either serialize the edits or have subagents produce patches that a coordinator applies.
- **Phase 8** — install guide, config examples, `diff-upstream.sh`, README, CHANGELOG are independent documents.

**Phases 1, 2, 4, 6 are sequential.** Each task modifies the same file as the previous task (e.g., Phase 2 repeatedly appends to `entrypoint.sh` with chained commits). Execute task-by-task without subagents.

**Pre-phase setup (one-time, before execution begins):**

- Phase 1 prereq: local checkout of `claude-agent-dispatch` at `~/claude-agent-dispatch` (used for vendoring).
- Phase 2 prereq: a GitHub test repo with a seeded issue containing an `<!-- agent-plan -->` comment. Use `recipe-manager-demo`.
- Phase 6 prereq: a test PR in the same repo with a CHANGES_REQUESTED review.
- Phase 7 caveat: macOS Keychain, Windows Credential Manager, and NTFS ACL adapters cannot be end-to-end tested on a Linux host. They ship blind on Linux-only runs and must be validated on a Windows machine before tagging v1.0. (Owner has committed to Windows-side validation pre-1.0.)

---

## Phase 1: Repository scaffold and base image

### Task 1.1: Initialize repository and baseline files

**Files:**
- Create: `~/repos/claude-pal/` (new directory + git repo)
- Create: `~/repos/claude-pal/README.md`
- Create: `~/repos/claude-pal/LICENSE`
- Create: `~/repos/claude-pal/.gitignore`
- Create: `~/repos/claude-pal/CLAUDE.md`
- Move: `/home/jonny/claude-pal-design.md` → `~/repos/claude-pal/docs/superpowers/specs/2026-04-18-claude-pal-design.md`
- Move: `/home/jonny/claude-pal-plan.md` → `~/repos/claude-pal/docs/superpowers/plans/2026-04-18-claude-pal.md`

- [ ] **Step 1: Create directory and initialize git**

```bash
mkdir -p ~/repos/claude-pal/docs/superpowers/{specs,plans}
cd ~/repos/claude-pal
git init
git branch -M main
```

- [ ] **Step 2: Move spec and plan into the repo**

```bash
mv /home/jonny/claude-pal-design.md ~/repos/claude-pal/docs/superpowers/specs/2026-04-18-claude-pal-design.md
mv /home/jonny/claude-pal-plan.md ~/repos/claude-pal/docs/superpowers/plans/2026-04-18-claude-pal.md
```

- [ ] **Step 3: Write `.gitignore`**

```gitignore
# Secrets
config.env
.pal/config.env

# Build artifacts
*.log
*.tmp

# OS files
.DS_Store
Thumbs.db

# Editor files
.vscode/
.idea/
*.swp
```

- [ ] **Step 4: Write `LICENSE` (MIT, matching upstream)**

```
MIT License

Copyright (c) 2026 <owner>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 5: Write `README.md` (minimal placeholder, expanded in Phase 8)**

```markdown
# claude-pal

Local agent dispatch via Claude Code skills. Ships fresh Claude Code containers against GitHub issues with a gated plan → implement → review pipeline.

See `docs/superpowers/specs/2026-04-18-claude-pal-design.md` for the design document.

**Status:** early development, v0.x. Not yet usable.
```

- [ ] **Step 6: Write `CLAUDE.md` (project instructions for future Claude sessions)**

```markdown
# claude-pal

Local agent dispatch via Claude Code skills.

## Key Documentation

- Full design: `docs/superpowers/specs/2026-04-18-claude-pal-design.md`
- Implementation plan: `docs/superpowers/plans/2026-04-18-claude-pal.md`
- Upstream tracking (vendored pieces): `UPSTREAM.md`

## Architecture

- `image/Dockerfile` — base Ubuntu image with claude CLI, gh, jq, git, iptables
- `image/opt/pal/entrypoint.sh` — pipeline orchestrator (bash)
- `image/opt/pal/allowlist.yaml` — firewall allowlist (data)
- `image/opt/pal/prompts/` — vendored adversarial/post-impl review prompts
- `image/opt/pal/lib/` — bash helpers (vendored review-gates.sh etc.)
- `.claude-plugin/plugin.json` — Claude Code plugin manifest
- `skills/pal-*/SKILL.md` — Claude Code skills (host-side)
- `lib/` — shared skill helpers (config loader, notifier, etc.); referenced via `${CLAUDE_PLUGIN_ROOT}/lib/...`
- `tests/` — BATS-Core tests

## Development

- All shell scripts must pass `shellcheck` with zero warnings
- Tests use BATS-Core
- Run checks: `shellcheck $(find . -name '*.sh') && bats tests/`
- Use `set -euo pipefail` in all scripts
```

- [ ] **Step 7: Initial commit**

```bash
cd ~/repos/claude-pal
git add .
git commit -m "chore: initial repo scaffold with spec and plan"
```

Expected: commit succeeds; `git log` shows one commit.

### Task 1.2: Check out claude-agent-dispatch for vendoring

**Files:**
- Read: `~/claude-agent-dispatch/prompts/adversarial-plan.md`
- Read: `~/claude-agent-dispatch/prompts/post-impl-review.md`
- Read: `~/claude-agent-dispatch/prompts/post-impl-retry.md`
- Read: `~/claude-agent-dispatch/prompts/implement.md`
- Read: `~/claude-agent-dispatch/scripts/lib/review-gates.sh`
- Read: `~/claude-agent-dispatch/scripts/lib/common.sh`

- [ ] **Step 1: Verify the local checkout is at the expected state**

```bash
cd ~/claude-agent-dispatch
git fetch origin
git log --oneline -5
git rev-parse HEAD  # record this as the upstream commit SHA for UPSTREAM.md
```

Expected: clean state on `main`, commits from upstream visible.

- [ ] **Step 2: Capture the upstream SHA for vendoring metadata**

Record the output of `git rev-parse HEAD` from step 1 — it will be written into `UPSTREAM.md` in Task 1.5.

### Task 1.3: Vendor prompts

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/prompts/adversarial-plan.md` (copied from upstream)
- Create: `~/repos/claude-pal/image/opt/pal/prompts/post-impl-review.md` (copied from upstream)
- Create: `~/repos/claude-pal/image/opt/pal/prompts/post-impl-retry.md` (copied from upstream)
- Create: `~/repos/claude-pal/image/opt/pal/prompts/implement.md` (copied from upstream, lightly adapted)

- [ ] **Step 1: Create directories**

```bash
mkdir -p ~/repos/claude-pal/image/opt/pal/prompts
```

- [ ] **Step 2: Copy adversarial-plan.md verbatim**

```bash
cp ~/claude-agent-dispatch/prompts/adversarial-plan.md ~/repos/claude-pal/image/opt/pal/prompts/
```

- [ ] **Step 3: Copy post-impl-review.md verbatim**

```bash
cp ~/claude-agent-dispatch/prompts/post-impl-review.md ~/repos/claude-pal/image/opt/pal/prompts/
```

- [ ] **Step 4: Copy post-impl-retry.md verbatim**

```bash
cp ~/claude-agent-dispatch/prompts/post-impl-retry.md ~/repos/claude-pal/image/opt/pal/prompts/
```

- [ ] **Step 5: Copy implement.md and lightly adapt**

```bash
cp ~/claude-agent-dispatch/prompts/implement.md ~/repos/claude-pal/image/opt/pal/prompts/
```

Now edit `~/repos/claude-pal/image/opt/pal/prompts/implement.md` to remove references to the label state machine. Specifically:
- Remove any mention of `agent:in-progress` or other `agent:*` labels
- Keep all TDD, self-review, and commit guidance
- The prompt's essence — "implement the approved plan with TDD, commit each cycle, do not open a PR" — is preserved

The adapted file's first section should read:

```markdown
You are implementing an approved plan for a GitHub issue in this repository, running inside an ephemeral claude-pal container.

## Issue Context
Read the issue details from environment variables:
- Run: echo "$AGENT_ISSUE_NUMBER" for the issue number
- Run: echo "$AGENT_ISSUE_TITLE" for the title
- Run: echo "$AGENT_ISSUE_BODY" for the description
- Run: echo "$AGENT_COMMENTS" for conversation context

## Approved Plan
Read the approved implementation plan:
- Run: echo "$AGENT_PLAN_CONTENT"

This plan has been reviewed and approved. Follow it closely.

[... rest of upstream implement.md content unchanged ...]
```

- [ ] **Step 6: Commit the vendored prompts**

```bash
cd ~/repos/claude-pal
git add image/opt/pal/prompts/
git commit -m "vendor: import review and implement prompts from claude-agent-dispatch"
```

### Task 1.4: Vendor review-gates library

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/lib/review-gates.sh` (copied from upstream)

- [ ] **Step 1: Copy review-gates.sh**

```bash
mkdir -p ~/repos/claude-pal/image/opt/pal/lib
cp ~/claude-agent-dispatch/scripts/lib/review-gates.sh ~/repos/claude-pal/image/opt/pal/lib/
```

- [ ] **Step 2: Adapt for single-session usage**

Edit `~/repos/claude-pal/image/opt/pal/lib/review-gates.sh`:

- The functions `run_adversarial_plan_review`, `run_post_impl_review`, `handle_post_impl_review_retry`, and the `_extract_review_json` helper are preserved verbatim.
- The helper functions they depend on (`load_prompt`, `run_claude`, `parse_claude_output`, `set_label`, `log`) are assumed to exist in sibling lib files — we'll provide adapted versions in Task 2.5 (run_claude, parse_claude_output) and Task 2.1 (log). The `set_label` calls in the upstream file must be **stubbed** since we don't have a label state machine:

Replace every `set_label "agent:failed"` with:

```bash
# No label state machine in claude-pal; status is written to status.json by the entrypoint
STATUS_OUTCOME="failure"
STATUS_FAILURE_REASON="adversarial_review_could_not_parse"  # or whatever context
```

And remove every `set_label "agent:needs-info"` or similar — replace with:

```bash
STATUS_OUTCOME="clarification_needed"
```

The `gh issue comment` calls within the review-gates functions are **preserved** — the container still posts comments for clarification questions; only the label side-effects are dropped.

- [ ] **Step 3: Run shellcheck on the adapted file**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/lib/review-gates.sh
```

Expected: zero warnings. Fix any that appear (usually unquoted expansions in the replaced sections).

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-pal
git add image/opt/pal/lib/review-gates.sh
git commit -m "vendor: import review-gates.sh, adapt for single-session flow"
```

### Task 1.5: Write UPSTREAM.md tracking

**Files:**
- Create: `~/repos/claude-pal/UPSTREAM.md`

- [ ] **Step 1: Write UPSTREAM.md with source paths, upstream SHA, and modification notes**

```markdown
# Upstream Vendored Files

This project vendors pieces of `jnurre64/claude-agent-dispatch`. Each file here is tracked with its source path, the upstream commit at time of vendor, and any local modifications.

Resync via `scripts/diff-upstream.sh` (see Phase 8).

## Prompts

| Local path | Source | Upstream SHA | Modifications |
|---|---|---|---|
| `image/opt/pal/prompts/adversarial-plan.md` | `prompts/adversarial-plan.md` | <SHA from Task 1.2> | none |
| `image/opt/pal/prompts/post-impl-review.md` | `prompts/post-impl-review.md` | <SHA from Task 1.2> | none |
| `image/opt/pal/prompts/post-impl-retry.md` | `prompts/post-impl-retry.md` | <SHA from Task 1.2> | none |
| `image/opt/pal/prompts/implement.md` | `prompts/implement.md` | <SHA from Task 1.2> | removed label-state-machine references; updated intro to mention claude-pal container |

## Libraries

| Local path | Source | Upstream SHA | Modifications |
|---|---|---|---|
| `image/opt/pal/lib/review-gates.sh` | `scripts/lib/review-gates.sh` | <SHA from Task 1.2> | replaced `set_label` calls with STATUS_* variable writes; kept gh issue comment calls |

## Conceptual patterns (not directly copied)

- Data-fetch pattern for gists and attachments (see `scripts/lib/data-fetch.sh` upstream) — reimplemented inline in our entrypoint with the same fetch-on-start, bind-to-env-var shape
- `_extract_review_json` helper — included in review-gates.sh above
```

Replace `<SHA from Task 1.2>` with the actual SHA recorded in Task 1.2 Step 1.

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add UPSTREAM.md
git commit -m "docs: add UPSTREAM.md tracking vendored files"
```

### Task 1.6: Write base Dockerfile

**Files:**
- Create: `~/repos/claude-pal/image/Dockerfile`

- [ ] **Step 1: Write Dockerfile**

```dockerfile
# Base image supports future sbx retargeting via BASE_IMAGE build arg
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq iptables sudo \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (for claude CLI npm install)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install claude CLI (official npm package)
RUN npm install -g @anthropic-ai/claude-code@latest

# Non-root user with sudo, matching sbx template convention for future portability
RUN useradd -m -s /bin/bash -G sudo agent \
    && echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent

# Copy pipeline assets
COPY --chown=root:root image/opt/pal /opt/pal
RUN chmod +x /opt/pal/entrypoint.sh /opt/pal/lib/*.sh 2>/dev/null || true

# Run as agent user by default
USER agent
WORKDIR /home/agent

ENTRYPOINT ["/opt/pal/entrypoint.sh"]
```

- [ ] **Step 2: Verify the file parses as a valid Dockerfile**

```bash
cd ~/repos/claude-pal
docker buildx build --target 0 -f image/Dockerfile . --dry-run 2>&1 | head -20 || true
# (--dry-run is newer docker; alternative: just try a build in step 3)
```

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-pal
git add image/Dockerfile
git commit -m "feat(image): initial Dockerfile with claude CLI, gh, jq, git"
```

### Task 1.7: Minimal entrypoint that logs and exits

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Write a minimal placeholder entrypoint (full pipeline in Phase 2)**

```bash
#!/bin/bash
set -euo pipefail

# ─── Args: <event_type> <repo> <number> ─────────────────────────
EVENT_TYPE="${1:?Usage: entrypoint.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"

# ─── Status file path (bind-mounted from host) ──────────────────
STATUS_DIR="${PAL_STATUS_DIR:-/status}"
mkdir -p "$STATUS_DIR"

log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$STATUS_DIR/log"
}

# ─── Placeholder for Phase 2: report a trivial success and exit ──
log "claude-pal entrypoint v0.1 (scaffold)"
log "EVENT_TYPE=$EVENT_TYPE REPO=$REPO NUMBER=$NUMBER"
log "Verifying claude CLI is present..."
claude --version | tee -a "$STATUS_DIR/log"
log "Verifying gh CLI is present..."
gh --version | tee -a "$STATUS_DIR/log"

cat > "$STATUS_DIR/status.json.tmp" <<EOF
{
  "phase": "complete",
  "outcome": "success",
  "failure_reason": null,
  "pr_number": null,
  "pr_url": null,
  "commits": [],
  "event_type": "$EVENT_TYPE",
  "repo": "$REPO",
  "number": $NUMBER
}
EOF
mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
log "Scaffold run complete."
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/entrypoint.sh
```

Expected: zero warnings.

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-pal
git add image/opt/pal/entrypoint.sh
git commit -m "feat(image): scaffold entrypoint.sh (writes status.json on exit)"
```

### Task 1.8: Image build and smoke test

**Files:**
- Create: `~/repos/claude-pal/scripts/build-image.sh`
- Create: `~/repos/claude-pal/tests/test_image_smoke.bats`

- [ ] **Step 1: Add BATS as a submodule**

```bash
cd ~/repos/claude-pal
git submodule add https://github.com/bats-core/bats-core.git tests/bats
git submodule add https://github.com/bats-core/bats-support.git tests/test_helper/bats-support
git submodule add https://github.com/bats-core/bats-assert.git tests/test_helper/bats-assert
git commit -m "chore(test): add BATS-core submodules"
```

- [ ] **Step 2: Write the image build script**

```bash
mkdir -p ~/repos/claude-pal/scripts
cat > ~/repos/claude-pal/scripts/build-image.sh <<'EOF'
#!/bin/bash
# Build the claude-pal base image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${1:-claude-pal:latest}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"

cd "$REPO_ROOT"
docker build \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -f image/Dockerfile \
    -t "$TAG" \
    .
EOF
chmod +x ~/repos/claude-pal/scripts/build-image.sh
```

- [ ] **Step 3: Write the smoke test**

> **Bind-mount permissions note (Linux hosts):** The Dockerfile runs the container as a non-root `agent` user created with `useradd -m` in the image, so `agent`'s UID is typically `1001` (not the host user's `1000`). When the entrypoint writes to the bind-mounted `/status` dir, Linux kernel file perms (not Docker) govern the write, so the host-side dir must be writable by the container user. `mktemp -d` creates a `0700` dir, which the container user cannot write to — the scaffold run fails with `tee: /status/log: Permission denied`. Fix: `chmod 0777` the status dir after `mktemp`. The Docker launcher in Task 3.4 applies the same treatment to each run's status dir.

```bash
cat > ~/repos/claude-pal/tests/test_image_smoke.bats <<'EOF'
#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    IMAGE_TAG="claude-pal:test-$RANDOM"
    STATUS_DIR="$(mktemp -d)"
    # Container runs as non-root "agent" user with a UID that usually
    # differs from the host's, so the bind-mounted status dir must be
    # writable by "other" for the entrypoint to write status.json/log.
    chmod 0777 "$STATUS_DIR"
}

teardown() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" 2>/dev/null || true
    [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
}

@test "image builds from scratch" {
    run "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG"
    assert_success
}

@test "scaffold entrypoint writes status.json and exits 0" {
    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1
    run docker run --rm \
        -v "$STATUS_DIR:/status" \
        "$IMAGE_TAG" implement owner/repo 42
    assert_success
    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
}
EOF
```

- [ ] **Step 4: Run the smoke test**

```bash
cd ~/repos/claude-pal
./tests/bats/bin/bats tests/test_image_smoke.bats
```

Expected: both tests pass. Image build is slow the first time (~5 minutes for base layers).

- [ ] **Step 5: Commit**

```bash
cd ~/repos/claude-pal
git add scripts/build-image.sh tests/test_image_smoke.bats
git commit -m "test(image): smoke test for image build and scaffold entrypoint"
```

**Milestone:** Running `./tests/bats/bin/bats tests/test_image_smoke.bats` builds the image and runs the scaffold entrypoint end-to-end. Phase 1 complete.

---

## Phase 2: Container entrypoint pipeline

### Task 2.1: Entrypoint skeleton with logging, status, and error trap

**Files:**
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Replace the scaffold entrypoint with structured skeleton**

```bash
#!/bin/bash
# shellcheck disable=SC1091  # Sourced lib files resolved at runtime
set -euo pipefail

# ─── Args: <event_type> <repo> <number> ─────────────────────────
EVENT_TYPE="${1:?Usage: entrypoint.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"

# ─── Paths ───────────────────────────────────────────────────────
PAL_HOME="/opt/pal"
PROMPTS_DIR="$PAL_HOME/prompts"
LIB_DIR="$PAL_HOME/lib"
STATUS_DIR="${PAL_STATUS_DIR:-/status}"
WORKTREE_DIR="${WORKTREE_DIR:-/home/agent/work}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/home/agent/.agent-data}"

mkdir -p "$STATUS_DIR" "$WORKTREE_DIR" "$AGENT_DATA_DIR"

# ─── Status tracking (mutated across phases, emitted at end) ────
STATUS_PHASE="init"
STATUS_OUTCOME="failure"            # default; set to "success" on happy path
STATUS_FAILURE_REASON=""
STATUS_PR_NUMBER="null"
STATUS_PR_URL="null"
STATUS_COMMITS="[]"
STATUS_REVIEW_CONCERNS_ADDRESSED="[]"
STATUS_REVIEW_CONCERNS_UNRESOLVED="[]"
STATUS_STARTED_AT="$(date -u +%FT%TZ)"

# ─── Logging ─────────────────────────────────────────────────────
LOG_FILE="$STATUS_DIR/log"
log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

# ─── status.json writer (atomic) ─────────────────────────────────
write_status() {
    local completed_at="${1:-$(date -u +%FT%TZ)}"
    cat > "$STATUS_DIR/status.json.tmp" <<EOF
{
  "phase": "$STATUS_PHASE",
  "outcome": "$STATUS_OUTCOME",
  "failure_reason": $([ -z "$STATUS_FAILURE_REASON" ] && echo null || printf '"%s"' "$STATUS_FAILURE_REASON"),
  "started_at": "$STATUS_STARTED_AT",
  "completed_at": "$completed_at",
  "pr_number": $STATUS_PR_NUMBER,
  "pr_url": $STATUS_PR_URL,
  "commits": $STATUS_COMMITS,
  "review_concerns_addressed": $STATUS_REVIEW_CONCERNS_ADDRESSED,
  "review_concerns_unresolved": $STATUS_REVIEW_CONCERNS_UNRESOLVED,
  "event_type": "$EVENT_TYPE",
  "repo": "$REPO",
  "number": $NUMBER
}
EOF
    mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
}

# ─── Global error trap: write a failure status before exit ──────
on_error() {
    local ec=$?
    [ "$ec" -eq 0 ] && return 0
    log "entrypoint failed at line ${1:-?} with exit code $ec (phase=$STATUS_PHASE)"
    if [ -z "$STATUS_FAILURE_REASON" ]; then
        STATUS_FAILURE_REASON="uncaught_error_at_line_${1:-unknown}_exit_${ec}"
    fi
    STATUS_OUTCOME="failure"
    write_status
}
trap 'on_error $LINENO' ERR
trap 'write_status' EXIT

# ─── Source lib files (review-gates provides gate functions) ────
# shellcheck source=/dev/null
. "$LIB_DIR/review-gates.sh"

# ─── Main pipeline (filled in by later tasks) ───────────────────
log "claude-pal v0.2 entrypoint"
log "event=$EVENT_TYPE repo=$REPO number=$NUMBER"

STATUS_PHASE="fetching_context"
# (Task 2.3 adds repo clone + worktree)
# (Task 2.4 adds issue/plan fetching)
# (Tasks 2.5–2.11 add pipeline phases)

# Placeholder for now so the skeleton runs to completion
STATUS_OUTCOME="success"
STATUS_PHASE="complete"
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/entrypoint.sh
```

Expected: zero warnings.

- [ ] **Step 3: Rebuild and rerun smoke test**

```bash
cd ~/repos/claude-pal
./tests/bats/bin/bats tests/test_image_smoke.bats
```

Expected: both tests still pass.

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-pal
git add image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): skeleton with logging, status tracking, error trap"
```

### Task 2.2: Firewall allowlist application

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/allowlist.yaml`
- Create: `~/repos/claude-pal/image/opt/pal/lib/firewall.sh`
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh` (source + call firewall apply)

- [ ] **Step 1: Write the default allowlist**

```yaml
# image/opt/pal/allowlist.yaml
# Outbound domains permitted from the container. Extended per-run via PAL_ALLOWLIST_EXTRA_DOMAINS.

domains:
  # Anthropic
  - api.anthropic.com
  - console.anthropic.com
  # GitHub
  - github.com
  - api.github.com
  - codeload.github.com
  - objects.githubusercontent.com
  - raw.githubusercontent.com
  - uploads.github.com
  # Package registries (base)
  - registry.npmjs.org
  - pypi.org
  - files.pythonhosted.org
  - api.nuget.org
  # Ubuntu repositories (for apt during build; runtime usually skips)
  - deb.debian.org
  - security.ubuntu.com
  - archive.ubuntu.com
```

- [ ] **Step 2: Write firewall.sh with iptables apply logic**

```bash
# image/opt/pal/lib/firewall.sh
# Apply deny-by-default outbound allowlist via iptables.
# Requires: iptables, dig (via host command), sudo
# Inputs: allowlist.yaml (domains list) + PAL_ALLOWLIST_EXTRA_DOMAINS env var

apply_firewall() {
    local allowlist_file="${1:-/opt/pal/allowlist.yaml}"
    local extra_domains_csv="${PAL_ALLOWLIST_EXTRA_DOMAINS:-}"

    if [ ! -f "$allowlist_file" ]; then
        log "firewall: allowlist file not found at $allowlist_file"
        return 1
    fi

    # Parse YAML (jq via yq-lite approach: very limited schema, one-level 'domains' list)
    local domains
    domains=$(awk '/^domains:/{flag=1;next}/^[^[:space:]-]/{flag=0}flag&&/^[[:space:]]*-[[:space:]]+/{gsub(/^[[:space:]]*-[[:space:]]+/,""); print}' "$allowlist_file")

    if [ -n "$extra_domains_csv" ]; then
        domains+=$'\n'
        domains+=$(printf '%s\n' "$extra_domains_csv" | tr ',' '\n' | tr -d ' ')
    fi

    log "firewall: allowlist contains $(printf '%s\n' "$domains" | grep -c . || true) domains"

    # Default policy: allow all loopback, deny all other outbound initially
    sudo iptables -F OUTPUT
    sudo iptables -P OUTPUT DROP
    sudo iptables -A OUTPUT -o lo -j ACCEPT
    # Allow DNS to resolver (so we can resolve domain names to IPs below)
    sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    # Allow established/related inbound responses
    sudo iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        local ips
        ips=$(getent ahosts "$domain" | awk '{print $1}' | sort -u || true)
        if [ -z "$ips" ]; then
            log "firewall: warning, could not resolve $domain (skipping)"
            continue
        fi
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            sudo iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
            sudo iptables -A OUTPUT -d "$ip" -p tcp --dport 80 -j ACCEPT
        done <<< "$ips"
    done <<< "$domains"

    log "firewall: allowlist applied (default-DROP with IP-pinned ACCEPT rules)"
}
```

- [ ] **Step 3: Wire firewall.sh into entrypoint**

In `~/repos/claude-pal/image/opt/pal/entrypoint.sh`, after the review-gates source line, add:

```bash
# shellcheck source=/dev/null
. "$LIB_DIR/firewall.sh"

STATUS_PHASE="applying_firewall"
apply_firewall "$PAL_HOME/allowlist.yaml" || {
    STATUS_FAILURE_REASON="firewall_apply_failed"
    exit 1
}
```

- [ ] **Step 4: shellcheck**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/lib/firewall.sh ~/repos/claude-pal/image/opt/pal/entrypoint.sh
```

Expected: zero warnings.

- [ ] **Step 5: Rebuild image and verify firewall rules install**

```bash
cd ~/repos/claude-pal
./scripts/build-image.sh claude-pal:dev
docker run --rm --cap-add=NET_ADMIN \
  -e CLAUDE_CODE_OAUTH_TOKEN=fake-for-smoke \
  -e GH_TOKEN=fake-for-smoke \
  -v /tmp/pal-smoke:/status \
  claude-pal:dev implement owner/repo 42 2>&1 | tail -30
cat /tmp/pal-smoke/status.json | jq .
```

Expected: log shows "firewall: allowlist applied (default-DROP with IP-pinned ACCEPT rules)" and status.json reports `"outcome": "success"` (because the rest of the pipeline is still stubbed).

Note: `--cap-add=NET_ADMIN` is required for iptables inside the container. The skill will pass this flag in Task 3.4.

- [ ] **Step 6: Commit**

```bash
cd ~/repos/claude-pal
git add image/opt/pal/allowlist.yaml image/opt/pal/lib/firewall.sh image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): apply deny-by-default iptables allowlist at startup"
```

### Task 2.3: Repo clone and worktree setup

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/lib/worktree.sh`
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Write worktree.sh**

```bash
# image/opt/pal/lib/worktree.sh
# Clone the target repo and create a worktree for this run.
# Uses GH_TOKEN for auth.

setup_worktree() {
    local repo="$1"       # owner/name
    local number="$2"     # issue or PR number
    local event_type="$3" # implement or revise

    local repo_cache="/home/agent/.cache/repos/$repo"
    local branch_name="agent/issue-${number}"

    # For revise, branch_name comes from the PR (filled in Task 6.1); for implement, we create it fresh
    mkdir -p "$(dirname "$repo_cache")"

    if [ ! -d "$repo_cache/.git" ]; then
        log "worktree: cloning $repo to $repo_cache"
        GH_TOKEN="$GH_TOKEN" gh repo clone "$repo" "$repo_cache" -- --no-tags
    else
        log "worktree: fetching latest for $repo"
        (cd "$repo_cache" && git fetch --prune origin)
    fi

    # Create worktree on a fresh branch from origin/main (implement) or from PR branch (revise)
    if [ "$event_type" = "revise" ]; then
        local pr_branch
        pr_branch=$(GH_TOKEN="$GH_TOKEN" gh pr view "$number" --repo "$repo" --json headRefName --jq .headRefName)
        log "worktree: checking out PR branch $pr_branch"
        (cd "$repo_cache" && git fetch origin "$pr_branch":"$pr_branch" 2>/dev/null || true)
        git -C "$repo_cache" worktree add "$WORKTREE_DIR" "$pr_branch"
        BRANCH_NAME="$pr_branch"
    else
        log "worktree: creating worktree on $branch_name from origin/main"
        git -C "$repo_cache" worktree add -B "$branch_name" "$WORKTREE_DIR" origin/main
        BRANCH_NAME="$branch_name"
    fi

    # Configure git identity inside the worktree
    local bot_name="${AGENT_GIT_USER_NAME:-claude-pal}"
    local bot_email="${AGENT_GIT_USER_EMAIL:-claude-pal@local}"
    git -C "$WORKTREE_DIR" config user.name "$bot_name"
    git -C "$WORKTREE_DIR" config user.email "$bot_email"

    log "worktree: ready at $WORKTREE_DIR on branch $BRANCH_NAME"
}
```

- [ ] **Step 2: Wire into entrypoint**

In `entrypoint.sh`, after the firewall block:

```bash
# shellcheck source=/dev/null
. "$LIB_DIR/worktree.sh"

STATUS_PHASE="cloning"
setup_worktree "$REPO" "$NUMBER" "$EVENT_TYPE" || {
    STATUS_FAILURE_REASON="worktree_setup_failed"
    exit 1
}
```

- [ ] **Step 3: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/lib/worktree.sh ~/repos/claude-pal/image/opt/pal/entrypoint.sh
cd ~/repos/claude-pal
git add image/opt/pal/lib/worktree.sh image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): clone repo and setup worktree per run"
```

### Task 2.4: Fetch issue body and plan comment

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/lib/fetch-context.sh`
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Write fetch-context.sh**

```bash
# image/opt/pal/lib/fetch-context.sh
# Fetch issue + plan comment (or PR context for revise) and export as env vars.

fetch_issue_context() {
    local repo="$1"
    local number="$2"

    local issue_json
    issue_json=$(gh issue view "$number" --repo "$repo" --json title,body,comments 2>/dev/null) || {
        log "fetch-context: failed to load issue $number on $repo"
        return 1
    }

    AGENT_ISSUE_NUMBER="$number"
    AGENT_ISSUE_TITLE=$(jq -r .title <<< "$issue_json")
    AGENT_ISSUE_BODY=$(jq -r .body <<< "$issue_json")
    AGENT_COMMENTS=$(jq -r '.comments[] | "## " + .author.login + " at " + .createdAt + "\n" + .body' <<< "$issue_json")

    # Find the latest <!-- agent-plan --> comment
    AGENT_PLAN_CONTENT=$(jq -r '[.comments[] | select(.body | startswith("<!-- agent-plan -->"))] | last | .body // ""' <<< "$issue_json" | sed 's|^<!-- agent-plan -->||')

    if [ -z "$AGENT_PLAN_CONTENT" ]; then
        log "fetch-context: no <!-- agent-plan --> comment found on issue $number"
        return 2  # caller handles "no plan" specially
    fi

    export AGENT_ISSUE_NUMBER AGENT_ISSUE_TITLE AGENT_ISSUE_BODY AGENT_COMMENTS AGENT_PLAN_CONTENT
    log "fetch-context: loaded issue $number (plan length: $(printf '%s' "$AGENT_PLAN_CONTENT" | wc -c) bytes)"
}

fetch_pr_context() {
    local repo="$1"
    local pr_number="$2"

    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$repo" --json title,body,comments,reviews,headRefName) || {
        log "fetch-context: failed to load PR $pr_number on $repo"
        return 1
    }

    AGENT_PR_NUMBER="$pr_number"
    AGENT_PR_TITLE=$(jq -r .title <<< "$pr_json")
    AGENT_PR_BODY=$(jq -r .body <<< "$pr_json")
    AGENT_PR_BRANCH=$(jq -r .headRefName <<< "$pr_json")

    # Gather review feedback (general + inline)
    AGENT_REVIEW_FEEDBACK=$(jq -r '
        [.reviews[] | select(.state=="CHANGES_REQUESTED") | "## Reviewer " + .author.login + " (" + .submittedAt + ")\n" + .body] +
        [.comments[] | "## Comment by " + .author.login + "\n" + .body]
        | join("\n\n")
    ' <<< "$pr_json")

    # Also fetch linked issue for plan lookup
    local linked_issue
    linked_issue=$(gh pr view "$pr_number" --repo "$repo" --json body --jq '.body' | grep -Eoi 'closes?[[:space:]]+#([0-9]+)' | head -1 | grep -Eo '[0-9]+' || true)
    if [ -n "$linked_issue" ]; then
        fetch_issue_context "$repo" "$linked_issue" || true
    fi

    export AGENT_PR_NUMBER AGENT_PR_TITLE AGENT_PR_BODY AGENT_PR_BRANCH AGENT_REVIEW_FEEDBACK
    log "fetch-context: loaded PR $pr_number (branch $AGENT_PR_BRANCH, review feedback length: $(printf '%s' "$AGENT_REVIEW_FEEDBACK" | wc -c) bytes)"
}
```

- [ ] **Step 2: Wire into entrypoint**

In `entrypoint.sh`, after the worktree block:

```bash
# shellcheck source=/dev/null
. "$LIB_DIR/fetch-context.sh"

STATUS_PHASE="fetching_context"
if [ "$EVENT_TYPE" = "implement" ]; then
    set +e
    fetch_issue_context "$REPO" "$NUMBER"
    ctx_rc=$?
    set -e
    if [ "$ctx_rc" -eq 2 ]; then
        STATUS_FAILURE_REASON="no_plan_found"
        exit 1
    elif [ "$ctx_rc" -ne 0 ]; then
        STATUS_FAILURE_REASON="issue_fetch_failed"
        exit 1
    fi
elif [ "$EVENT_TYPE" = "revise" ]; then
    fetch_pr_context "$REPO" "$NUMBER" || {
        STATUS_FAILURE_REASON="pr_fetch_failed"
        exit 1
    }
else
    STATUS_FAILURE_REASON="unknown_event_type_${EVENT_TYPE}"
    exit 1
fi
```

- [ ] **Step 3: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/lib/fetch-context.sh
cd ~/repos/claude-pal
git add image/opt/pal/lib/fetch-context.sh image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): fetch issue/plan or PR context from GitHub"
```

### Task 2.5: run_claude and load_prompt helpers

**Files:**
- Create: `~/repos/claude-pal/image/opt/pal/lib/claude-runner.sh`
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Write claude-runner.sh**

```bash
# image/opt/pal/lib/claude-runner.sh
# Invoke claude -p with phase-specific tool allowlists and parse JSON output.

load_prompt() {
    local name="$1"
    local path="$PROMPTS_DIR/${name}.md"
    if [ ! -f "$path" ]; then
        log "claude-runner: prompt not found at $path"
        return 1
    fi
    cat "$path"
}

run_claude() {
    local prompt="$1"
    local allowed_tools="${2:-Read,Write,Edit,Bash(git *),Bash(ls *)}"
    local model_override="${3:-}"

    cd "$WORKTREE_DIR"
    local stderr_log="$STATUS_DIR/claude-stderr-$(date +%s).log"
    local claude_args=(
        -p "$prompt"
        --allowedTools "$allowed_tools"
        --disallowedTools "${AGENT_DISALLOWED_TOOLS:-mcp__github__*}"
        --max-turns "${AGENT_MAX_TURNS:-50}"
        --output-format json
    )
    if [ -n "$model_override" ]; then
        claude_args+=(--model "$model_override")
    fi

    local timeout="${AGENT_TIMEOUT:-3600}"
    timeout "$timeout" claude "${claude_args[@]}" 2>"$stderr_log" || {
        local ec=$?
        log "claude-runner: claude exited with code $ec (stderr: $(head -10 "$stderr_log"))"
        echo '{"result":"claude timed out or errored","error":true}'
    }
}

parse_claude_output() {
    local result="$1"
    local out
    out=$(echo "$result" | jq -r '.result // .result_text // empty' 2>/dev/null || echo "")
    if [ -z "$out" ]; then
        out="$result"
    fi
    echo "$out"
}
```

- [ ] **Step 2: Wire into entrypoint**

In `entrypoint.sh`, after the other source lines:

```bash
# shellcheck source=/dev/null
. "$LIB_DIR/claude-runner.sh"
```

- [ ] **Step 3: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/lib/claude-runner.sh
cd ~/repos/claude-pal
git add image/opt/pal/lib/claude-runner.sh image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): add claude-runner lib (load_prompt, run_claude, parse_claude_output)"
```

### Task 2.6: Gate A — adversarial plan review

**Files:**
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Wire Gate A into the pipeline**

In `entrypoint.sh`, after the fetch_context block, for `implement` event type only:

```bash
if [ "$EVENT_TYPE" = "implement" ]; then
    STATUS_PHASE="adversarial_review"
    AGENT_ADVERSARIAL_PLAN_REVIEW="${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}"
    AGENT_ALLOWED_TOOLS_TRIAGE="${AGENT_ALLOWED_TOOLS_TRIAGE:-Read,Glob,Grep,Bash(ls *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(echo *)}"
    AGENT_MODEL_ADVERSARIAL_PLAN="${AGENT_MODEL_ADVERSARIAL_PLAN:-}"
    if ! run_adversarial_plan_review; then
        # review-gates.sh sets STATUS_OUTCOME and STATUS_FAILURE_REASON on failure modes
        exit 1
    fi
fi
```

- [ ] **Step 2: Verify review-gates.sh's run_adversarial_plan_review references these env vars**

Check the vendored file mentions `AGENT_ADVERSARIAL_PLAN_REVIEW`, `AGENT_ALLOWED_TOOLS_TRIAGE`, `AGENT_MODEL_ADVERSARIAL_PLAN`. If any are referenced under different names, normalize in Task 1.4's adaptation.

- [ ] **Step 3: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/entrypoint.sh
cd ~/repos/claude-pal
git add image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): Gate A adversarial plan review wired in for implement flow"
```

### Task 2.7: Implement phase with TDD retry loop

**Files:**
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Add the implement phase with retry loop**

In `entrypoint.sh`, after Gate A:

```bash
STATUS_PHASE="implementing"
AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT:-Read,Write,Edit,Glob,Grep,Bash(git *),Bash(ls *),Bash(cat *),Bash(echo *),Bash(mkdir *),Bash(mv *),Bash(cp *),Bash(rm *),Bash(chmod *)}"
# Plus project-specific test and setup command tools:
if [ -n "${AGENT_TEST_COMMAND:-}" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_COMMAND%% *} *)"
fi
if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_SETUP_COMMAND%% *} *)"
fi
AGENT_MODEL_IMPLEMENT="${AGENT_MODEL_IMPLEMENT:-}"

# Load appropriate prompt (implement for issue, revise for PR feedback)
if [ "$EVENT_TYPE" = "revise" ]; then
    impl_prompt=$(load_prompt "post-impl-retry")  # Reuse retry prompt for PR revise
    export AGENT_REVIEW_CONCERNS="$AGENT_REVIEW_FEEDBACK"
else
    impl_prompt=$(load_prompt "implement")
fi

# Capture starting SHA to detect "no commits" case
start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

# TDD retry loop: run implement; if tests fail, feed output back; up to N retries
AGENT_IMPL_MAX_RETRIES="${AGENT_IMPL_MAX_RETRIES:-2}"
retry=0
while [ "$retry" -le "$AGENT_IMPL_MAX_RETRIES" ]; do
    log "implement: attempt $((retry+1)) of $((AGENT_IMPL_MAX_RETRIES+1))"
    result=$(run_claude "$impl_prompt" "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "$AGENT_MODEL_IMPLEMENT")
    claude_output=$(parse_claude_output "$result")
    log "implement: claude output (first 500 chars): ${claude_output:0:500}"

    # If AGENT_TEST_COMMAND is set, run it; pass on green, feed failure back if red
    if [ -n "${AGENT_TEST_COMMAND:-}" ]; then
        STATUS_PHASE="testing"
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") >> "$LOG_FILE" 2>&1 || log "warn: test setup exited non-zero"
        fi

        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e

        if [ "$test_exit" -eq 0 ]; then
            log "implement: tests green on attempt $((retry+1))"
            break
        fi

        log "implement: tests failed on attempt $((retry+1)); feeding output back"
        # Extend the prompt with failing output for next iteration
        impl_prompt="$impl_prompt

## Previous attempt failed tests
\`\`\`
$(echo "$test_output" | tail -80)
\`\`\`

The code you just wrote did not pass tests. Investigate, fix, and try again."
        retry=$((retry+1))
    else
        log "implement: no AGENT_TEST_COMMAND set; accepting implement output as-is"
        break
    fi
done

if [ -n "${AGENT_TEST_COMMAND:-}" ] && [ "$test_exit" -ne 0 ]; then
    STATUS_FAILURE_REASON="tests_failed_after_${AGENT_IMPL_MAX_RETRIES}_retries"
    exit 1
fi

# Capture post-implement commits
end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
if [ "$start_sha" = "$end_sha" ]; then
    STATUS_FAILURE_REASON="empty_diff"
    exit 1
fi

STATUS_COMMITS=$(git -C "$WORKTREE_DIR" log --format='"%h"' "${start_sha}..${end_sha}" | jq -s 'map(.|tostring|fromjson)' -R | jq -sc '.[0]' 2>/dev/null || echo '[]')
log "implement: captured $(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..${end_sha}") new commits"
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/entrypoint.sh
cd ~/repos/claude-pal
git add image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): implement phase with TDD retry loop and test-fail feedback"
```

### Task 2.8: Gate B — post-impl review and retry

**Files:**
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Add Gate B after implement**

In `entrypoint.sh`, after the implement block:

```bash
STATUS_PHASE="post_impl_review"
AGENT_POST_IMPL_REVIEW="${AGENT_POST_IMPL_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-1}"
AGENT_MODEL_POST_IMPL_REVIEW="${AGENT_MODEL_POST_IMPL_REVIEW:-}"
AGENT_MODEL_POST_IMPL_RETRY="${AGENT_MODEL_POST_IMPL_RETRY:-}"

if ! run_post_impl_review; then
    # review-gates.sh sets POST_IMPL_REVIEW_CONCERNS
    STATUS_PHASE="post_impl_retry"
    if ! handle_post_impl_review_retry "$AGENT_ALLOWED_TOOLS_IMPLEMENT"; then
        STATUS_OUTCOME="review_concerns_unresolved"
        STATUS_REVIEW_CONCERNS_UNRESOLVED=$(jq -Rs 'split("\n") | map(select(. != ""))' <<< "$POST_IMPL_REVIEW_CONCERNS")
        STATUS_FAILURE_REASON="post_impl_review_unresolved"
        exit 1
    else
        STATUS_REVIEW_CONCERNS_ADDRESSED=$(jq -Rs 'split("\n") | map(select(. != ""))' <<< "$REVIEW_RETRY_CONCERNS")
    fi
fi
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/entrypoint.sh
cd ~/repos/claude-pal
git add image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): Gate B post-impl review + retry with concern handling"
```

### Task 2.9: Push branch and create PR

**Files:**
- Modify: `~/repos/claude-pal/image/opt/pal/entrypoint.sh`

- [ ] **Step 1: Add push + PR create for implement; push-only for revise**

In `entrypoint.sh`, after Gate B:

```bash
STATUS_PHASE="pushing_pr"

# Push branch
if ! git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME"; then
    STATUS_FAILURE_REASON="git_push_failed"
    exit 1
fi
log "pushed branch $BRANCH_NAME"

if [ "$EVENT_TYPE" = "revise" ]; then
    # No new PR; the existing PR picks up the push
    STATUS_PR_NUMBER="$NUMBER"
    existing_pr_url=$(gh pr view "$NUMBER" --repo "$REPO" --json url --jq .url)
    STATUS_PR_URL="\"$existing_pr_url\""
    log "revise: new commits pushed to existing PR #$NUMBER"
else
    # Create PR
    local_pr_title="${AGENT_ISSUE_TITLE:-claude-pal implementation}"
    local_pr_body="Closes #${NUMBER}

Implemented by claude-pal based on the approved plan in issue #${NUMBER}."

    pr_create_output=$(gh pr create \
        --repo "$REPO" \
        --title "$local_pr_title" \
        --body "$local_pr_body" \
        --base main \
        --head "$BRANCH_NAME" 2>&1) || {
            STATUS_FAILURE_REASON="pr_create_failed: ${pr_create_output}"
            exit 1
        }
    STATUS_PR_URL="\"$(echo "$pr_create_output" | tail -1)\""
    STATUS_PR_NUMBER=$(echo "$STATUS_PR_URL" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+')
    log "created PR at $STATUS_PR_URL"
fi

STATUS_OUTCOME="success"
STATUS_PHASE="complete"
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/image/opt/pal/entrypoint.sh
cd ~/repos/claude-pal
git add image/opt/pal/entrypoint.sh
git commit -m "feat(entrypoint): push branch and create PR (or update PR for revise)"
```

### Task 2.10: End-to-end container pipeline test

**Files:**
- Create: `~/repos/claude-pal/tests/test_container_pipeline.bats`
- Requires: a test GitHub repo the developer owns + a test issue with a trivial plan

- [ ] **Step 1: Prepare a test repo and issue manually**

This is a one-time manual step (documented here; tests use repo name env var):
1. Create a toy repo in your GitHub account, e.g., `claude-pal-smoketest`
2. Add a README and a trivial test file with a failing test
3. Open an issue with a minimal `<!-- agent-plan -->` comment describing a trivial fix

- [ ] **Step 2: Write the integration test**

```bash
cat > ~/repos/claude-pal/tests/test_container_pipeline.bats <<'EOF'
#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    IMAGE_TAG="claude-pal:test-pipeline-$RANDOM"
    STATUS_DIR="$(mktemp -d)"
    TEST_REPO="${PAL_TEST_REPO:?set PAL_TEST_REPO to owner/claude-pal-smoketest}"
    TEST_ISSUE="${PAL_TEST_ISSUE:?set PAL_TEST_ISSUE to the test issue number}"
    : "${CLAUDE_CODE_OAUTH_TOKEN:?required}"
    : "${GH_TOKEN:?required}"
}

teardown() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" 2>/dev/null || true
    [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
}

@test "full implement pipeline round-trips on smoketest issue" {
    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1

    run docker run --rm \
        --cap-add=NET_ADMIN \
        -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        -e GH_TOKEN="$GH_TOKEN" \
        -e AGENT_TEST_COMMAND="${PAL_TEST_CMD:-}" \
        -v "$STATUS_DIR:/status" \
        --timeout 1800 \
        "$IMAGE_TAG" implement "$TEST_REPO" "$TEST_ISSUE"
    assert_success

    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"

    run jq -r '.pr_url' "$STATUS_DIR/status.json"
    refute_output "null"
}
EOF
```

- [ ] **Step 3: Run the integration test**

```bash
cd ~/repos/claude-pal
export PAL_TEST_REPO="yourname/claude-pal-smoketest"
export PAL_TEST_ISSUE="1"
export CLAUDE_CODE_OAUTH_TOKEN="$(cat ~/.config/claude-dispatch/oauth.env 2>/dev/null || echo)"
export GH_TOKEN="$(cat ~/.config/gh-tokens/dispatch-cli-token 2>/dev/null || echo)"
./tests/bats/bin/bats tests/test_container_pipeline.bats
```

Expected: test completes (may take 5–15 minutes depending on the trivial fix). A PR appears in the test repo. Status.json shows `"outcome": "success"` and non-null `pr_url`.

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-pal
git add tests/test_container_pipeline.bats
git commit -m "test(container): end-to-end pipeline integration test"
```

**Milestone:** `docker run` against a test repo round-trips an issue+plan to an opened PR via the full gated pipeline. Phase 2 complete.

---

## Phase 3: `/pal-implement` skill (sync mode)

> **Plugin layout (applies to all Phase 3–6 tasks).** The host-side skills are a Claude Code plugin. The canonical layout (per the official `plugin-dev/plugin-structure` skill) is:
>
> ```
> ~/repos/claude-pal/
> ├── .claude-plugin/plugin.json   # plugin manifest
> ├── lib/                         # shared bash helpers (plugin root!)
> │   ├── config.sh
> │   ├── preflight.sh
> │   └── …
> └── skills/
>     ├── pal-implement/SKILL.md
>     ├── pal-plan/SKILL.md
>     └── …
> ```
>
> **Shared helpers go at plugin-root `lib/`, NOT under `skills/lib/`.** SKILL.md files resolve them via `${CLAUDE_PLUGIN_ROOT}`, which Claude Code populates at skill-invocation time:
>
> ```bash
> . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
> ```
>
> This matches the pattern used by the official `plugin-dev` plugin (see `plugin-dev/skills/plugin-structure/references/component-patterns.md`, "Shared Resources") and by `superpowers` itself (`hooks/session-start` reads `${CLAUDE_PLUGIN_ROOT}` directly). Do not use `$(dirname "$(claude-skill-path …)")` dances — that pseudo-command does not exist.

### Task 3.1: Plugin manifest, skill directory structure, and config loader

**Files:**
- Create: `~/repos/claude-pal/.claude-plugin/plugin.json`
- Create: `~/repos/claude-pal/skills/pal-implement/` (directory)
- Create: `~/repos/claude-pal/lib/config.sh`

- [ ] **Step 1: Write the plugin manifest**

```bash
mkdir -p ~/repos/claude-pal/.claude-plugin ~/repos/claude-pal/lib ~/repos/claude-pal/skills/pal-implement

cat > ~/repos/claude-pal/.claude-plugin/plugin.json <<'EOF'
{
  "name": "claude-pal",
  "version": "0.1.0",
  "description": "Local agent dispatch for Claude Code — publishes implementation plans to GitHub and runs a gated pipeline (adversarial plan review → TDD implement → post-impl review → PR) inside an ephemeral Docker container.",
  "author": { "name": "jnurre64" },
  "repository": "https://github.com/jnurre64/claude-pal",
  "license": "MIT",
  "keywords": ["agents", "automation", "github", "docker"]
}
EOF
```

- [ ] **Step 2: Write the config loader**

```bash
cat > ~/repos/claude-pal/lib/config.sh <<'EOF'
# lib/config.sh
# Resolve and load the claude-pal host config.
# Returns config values via stdout or sets variables depending on caller.

pal_config_path() {
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux|Darwin)
            echo "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pal/config.env"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Git Bash on Windows
            local local_app
            local_app=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")
            echo "$local_app/claude-pal/config.env"
            ;;
        *)
            echo "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pal/config.env"
            ;;
    esac
}

pal_load_config() {
    local path
    path=$(pal_config_path)
    if [ ! -f "$path" ]; then
        echo "pal: config file not found at $path" >&2
        echo "pal: run 'pal-setup' or create the file manually — see docs/install.md" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "$path"
}

pal_config_permissions_ok() {
    local path
    path=$(pal_config_path)
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux|Darwin)
            local perms
            perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%A' "$path" 2>/dev/null)
            if [ "$perms" != "600" ]; then
                echo "pal: config file $path has permissions $perms, expected 600" >&2
                echo "pal: run 'chmod 600 \"$path\"' and retry" >&2
                return 1
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Windows: check NTFS ACL via icacls; simplified presence check for v1
            # Full ACL validation is in Task 7.4
            ;;
    esac
}
EOF
```

- [ ] **Step 3: shellcheck**

```bash
shellcheck ~/repos/claude-pal/lib/config.sh
```

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-pal
git add .claude-plugin/plugin.json lib/config.sh skills/pal-implement/
git commit -m "feat(plugin): manifest + config loader at plugin-root lib/"
```

### Task 3.2: Preflight check helpers

**Files:**
- Create: `~/repos/claude-pal/lib/preflight.sh`

- [ ] **Step 1: Write preflight checks**

```bash
cat > ~/repos/claude-pal/lib/preflight.sh <<'EOF'
# lib/preflight.sh
# Preflight checks run before every dispatch.

pal_preflight_no_api_key_in_env() {
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "pal: ERROR — ANTHROPIC_API_KEY is set in your environment." >&2
        echo "pal: This would silently override your CLAUDE_CODE_OAUTH_TOKEN and bill a Console account." >&2
        echo "pal: Unset it with: unset ANTHROPIC_API_KEY" >&2
        return 1
    fi
}

pal_preflight_single_auth_method() {
    local has_oauth=0 has_api=0
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && has_oauth=1
    [ -n "${ANTHROPIC_API_KEY:-}" ] && has_api=1
    local count=$((has_oauth + has_api))
    if [ "$count" -eq 0 ]; then
        echo "pal: ERROR — neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set in config.env" >&2
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "pal: ERROR — both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are in config.env" >&2
        echo "pal: Set exactly one. See docs/authentication.md." >&2
        return 1
    fi
}

pal_preflight_docker_reachable() {
    if ! docker info > /dev/null 2>&1; then
        local target="${DOCKER_HOST:-local}"
        echo "pal: ERROR — docker daemon not reachable (DOCKER_HOST=$target)" >&2
        return 1
    fi
}

pal_preflight_windows_bash() {
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        MINGW*|MSYS*|CYGWIN*)
            local bash_version
            bash_version=$(bash --version | head -1)
            if echo "$bash_version" | grep -qi wsl; then
                echo "pal: ERROR — Claude Code is using WSL's bash, not Git Bash" >&2
                echo "pal: Set CLAUDE_CODE_GIT_BASH_PATH in your Claude Code settings.json:" >&2
                echo "pal:   {\"env\": {\"CLAUDE_CODE_GIT_BASH_PATH\": \"C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe\"}}" >&2
                return 1
            fi
            ;;
    esac
}

pal_preflight_gh_auth() {
    if [ -z "${GH_TOKEN:-}" ]; then
        echo "pal: ERROR — GH_TOKEN not set in config.env" >&2
        return 1
    fi
    if ! GH_TOKEN="$GH_TOKEN" gh auth status > /dev/null 2>&1; then
        echo "pal: WARN — gh auth status failed with configured token" >&2
        # Non-fatal: some PATs return 200 but fail auth status; let the container try
    fi
}

pal_preflight_issue_not_in_flight() {
    local repo="$1"
    local number="$2"
    local lock
    lock="$(pal_runs_dir)/.lock-${repo//\//_}-${number}"
    if [ -f "$lock" ]; then
        local existing_run
        existing_run=$(cat "$lock")
        echo "pal: ERROR — another run is already in flight for $repo#$number (run $existing_run)" >&2
        echo "pal: Use '/pal-status $existing_run' to check its state, or '/pal-cancel $existing_run' to kill it" >&2
        return 1
    fi
}

pal_preflight_all() {
    local repo="${1:-}"
    local number="${2:-}"

    pal_preflight_no_api_key_in_env &&
    pal_load_config &&
    pal_config_permissions_ok &&
    pal_preflight_single_auth_method &&
    pal_preflight_docker_reachable &&
    pal_preflight_windows_bash &&
    pal_preflight_gh_auth || return 1

    if [ -n "$repo" ] && [ -n "$number" ]; then
        pal_preflight_issue_not_in_flight "$repo" "$number" || return 1
    fi
}
EOF
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck ~/repos/claude-pal/lib/preflight.sh
```

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-pal
git add lib/preflight.sh
git commit -m "feat(plugin): preflight check helpers (auth, docker, windows-bash, gh, lock)"
```

### Task 3.3: Run registry helper

**Files:**
- Create: `~/repos/claude-pal/lib/runs.sh`

- [ ] **Step 1: Write runs.sh**

```bash
cat > ~/repos/claude-pal/lib/runs.sh <<'EOF'
# lib/runs.sh
# Run registry: directory layout, run id generation, reconciliation.

pal_runs_dir() {
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux|Darwin)
            echo "${XDG_DATA_HOME:-$HOME/.local/share}/claude-pal/runs"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            local local_app
            local_app=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")
            echo "$local_app/claude-pal/runs"
            ;;
    esac
}

pal_new_run_id() {
    printf '%s-%s' "$(date +%Y-%m-%d-%H%M)" "$(head /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 6)"
}

pal_run_dir() {
    local run_id="$1"
    echo "$(pal_runs_dir)/$run_id"
}

pal_write_launch_meta() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local event_type="$4"
    local mode="$5"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    mkdir -p "$run_dir"
    cat > "$run_dir/launch_meta.json" <<EOF_META
{
  "run_id": "$run_id",
  "event_type": "$event_type",
  "repo": "$repo",
  "issue_number": $([ "$event_type" = "implement" ] && echo "$number" || echo "null"),
  "pr_number": $([ "$event_type" = "revise" ] && echo "$number" || echo "null"),
  "mode": "$mode",
  "started_at": "$(date -u +%FT%TZ)",
  "host_os": "$(uname -s)",
  "backend": "${PAL_BACKEND:-docker-linux}",
  "docker_host": $([ -n "${DOCKER_HOST:-}" ] && printf '"%s"' "$DOCKER_HOST" || echo null),
  "image_tag": "${PAL_IMAGE_TAG:-claude-pal:latest}"
}
EOF_META
}

pal_acquire_lock() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local lock
    lock="$(pal_runs_dir)/.lock-${repo//\//_}-${number}"
    echo "$run_id" > "$lock"
}

pal_release_lock() {
    local repo="$1"
    local number="$2"
    local lock
    lock="$(pal_runs_dir)/.lock-${repo//\//_}-${number}"
    rm -f "$lock"
}
EOF
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/runs.sh
cd ~/repos/claude-pal
git add lib/runs.sh
git commit -m "feat(plugin): run registry helpers (dir layout, run ids, lock files)"
```

### Task 3.4: Docker launcher (sync mode)

**Files:**
- Create: `~/repos/claude-pal/lib/launcher.sh`

> **Bind-mount permissions (Linux hosts):** The container runs as the non-root `agent` user defined in the Dockerfile. On Linux, that user's UID usually differs from the host user's, so the bind-mounted `/status` dir needs to be writable by "other" or the entrypoint's `tee`/status writes fail with `Permission denied`. The launcher `chmod 0777`s `run_dir` before `docker run`. (On macOS/Docker Desktop the virtualized file sharing rewrites ownership, so this is effectively a no-op there; on Windows/Docker Desktop the NTFS ACL check in Phase 7 covers the analogous concern.) The Phase 1 smoke test already applies this chmod for the same reason.

- [ ] **Step 1: Write launcher.sh**

```bash
cat > ~/repos/claude-pal/lib/launcher.sh <<'EOF'
# lib/launcher.sh
# Backend adapter: launches the container via docker run.

pal_launch_sync() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local event_type="$4"   # implement or revise

    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local image_tag="${PAL_IMAGE_TAG:-claude-pal:latest}"

    # Make the bind-mounted status dir writable by the container's non-root
    # agent user (UID differs from host on Linux). See note above.
    chmod 0777 "$run_dir"

    # Per-repo config (if present in current working directory's .pal/)
    local per_repo_config=".pal/config.env"
    local per_repo_args=()
    if [ -f "$per_repo_config" ]; then
        # Source, then translate each PAL_-namespaced or AGENT_-namespaced variable into -e args
        # (we read, then use `env` to pass through)
        local per_repo_env
        per_repo_env=$(grep -E '^(AGENT_|PAL_|DOCKER_HOST=)' "$per_repo_config" | grep -v '^#' || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            per_repo_args+=(-e "$line")
        done <<< "$per_repo_env"
    fi

    local docker_args=(
        run --rm
        --cap-add=NET_ADMIN
        -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
        -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
        -e GH_TOKEN="$GH_TOKEN"
        -v "$run_dir:/status"
    )
    docker_args+=("${per_repo_args[@]}")
    docker_args+=("$image_tag" "$event_type" "$repo" "$number")

    pal_acquire_lock "$run_id" "$repo" "$number"

    # Sync mode: run in foreground, tee to log
    local exit_code=0
    docker "${docker_args[@]}" 2>&1 | tee "$run_dir/log" || exit_code=$?

    pal_release_lock "$repo" "$number"
    return $exit_code
}

pal_render_status_summary() {
    local run_id="$1"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local status_file="$run_dir/status.json"

    if [ ! -f "$status_file" ]; then
        echo "pal: no status.json found at $status_file" >&2
        return 1
    fi

    local outcome phase pr_url failure_reason
    outcome=$(jq -r .outcome "$status_file")
    phase=$(jq -r .phase "$status_file")
    pr_url=$(jq -r .pr_url "$status_file")
    failure_reason=$(jq -r .failure_reason "$status_file")

    case "$outcome" in
        success)
            printf '✓ claude-pal run %s: success\n' "$run_id"
            printf '  PR opened: %s\n' "$pr_url"
            ;;
        clarification_needed)
            printf '? claude-pal run %s: clarification needed\n' "$run_id"
            printf '  Respond on the issue, then re-run /pal-implement\n'
            ;;
        review_concerns_unresolved)
            printf '⚠ claude-pal run %s: post-impl review concerns unresolved\n' "$run_id"
            printf '  Review the branch manually. Concerns:\n'
            jq -r '.review_concerns_unresolved[]' "$status_file" | sed 's/^/    - /'
            ;;
        failure)
            printf '✗ claude-pal run %s: failed at phase %s\n' "$run_id" "$phase"
            printf '  Reason: %s\n' "$failure_reason"
            printf '  Log: %s/log\n' "$run_dir"
            ;;
        cancelled)
            printf '✗ claude-pal run %s: cancelled\n' "$run_id"
            ;;
        *)
            printf '? claude-pal run %s: unknown outcome "%s"\n' "$run_id" "$outcome"
            ;;
    esac
}
EOF
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/launcher.sh
cd ~/repos/claude-pal
git add lib/launcher.sh
git commit -m "feat(plugin): docker sync launcher and status pretty-printer"
```

### Task 3.5: `/pal-implement` skill markdown

**Files:**
- Create: `~/repos/claude-pal/skills/pal-implement/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

```markdown
---
name: pal-implement
description: Launch an ephemeral Docker container that executes the posted plan on a GitHub issue. Runs a gated pipeline (adversarial plan review → TDD implementation → post-impl review → PR open). Sync by default; pass --async to background.
---

# pal-implement

Launch a claude-pal container to implement a GitHub issue's posted plan.

## Usage

```
/pal-implement <issue#> [--async]
```

## Steps

1. Parse arguments. Require exactly one positional argument (issue number); `--async` flag is optional.
2. Source the shared libs (`${CLAUDE_PLUGIN_ROOT}` is set by Claude Code when the skill fires):
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/preflight.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
3. Determine the target repo. If the current working directory is inside a git repo, use its origin remote. Otherwise require `PAL_REPO` env var.
4. Run `pal_preflight_all "$repo" "$issue_num"`. On failure, exit with the preflight's own error.
5. Generate a run id: `run_id=$(pal_new_run_id)`.
6. Write launch meta: `pal_write_launch_meta "$run_id" "$repo" "$issue_num" "implement" "sync"`.
7. Launch: `pal_launch_sync "$run_id" "$repo" "$issue_num" "implement"`. Exit code propagates.
8. After container exits, call `pal_render_status_summary "$run_id"`.

If `--async` flag is given, instead of steps 6-8 use the async path (implemented in Phase 5).

## Examples

- `/pal-implement 42` — launches container synchronously, blocks until done.
- `/pal-implement 42 --async` — launches container in background (requires Phase 5).
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add skills/pal-implement/SKILL.md
git commit -m "feat(plugin): pal-implement SKILL.md (sync mode)"
```

### Task 3.6: Skill smoke test

**Files:**
- Create: `~/repos/claude-pal/tests/test_skill_pal_implement.bats`

- [ ] **Step 1: Write the test (mocks docker)**

```bash
cat > ~/repos/claude-pal/tests/test_skill_pal_implement.bats <<'EOF'
#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"

    mkdir -p "$XDG_CONFIG_HOME/claude-pal"
    cat > "$XDG_CONFIG_HOME/claude-pal/config.env" <<'CONFIG'
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake
GH_TOKEN=github_pat_fake
CONFIG
    chmod 600 "$XDG_CONFIG_HOME/claude-pal/config.env"

    # Mock docker with a script that writes a fake status.json
    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"
    cat > "$TMPHOME/bin/docker" <<'DOCKER_MOCK'
#!/bin/bash
case "$1" in
    info) exit 0 ;;
    run)
        # Find the -v bind mount for status
        status_dir=$(echo "$@" | grep -oE '/tmp[^:]+:/status' | cut -d: -f1 | head -1)
        [ -z "$status_dir" ] && status_dir=$(echo "$@" | grep -oE '[^ ]+/claude-pal/runs/[^:]+:/status' | cut -d: -f1 | head -1)
        if [ -n "$status_dir" ] && [ -d "$status_dir" ]; then
            cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/x/y/pull/99","pr_number":99,"failure_reason":null}
EOF_STATUS
        fi
        exit 0
        ;;
    *) exit 1 ;;
esac
DOCKER_MOCK
    chmod +x "$TMPHOME/bin/docker"
}

teardown() {
    rm -rf "$TMPHOME"
}

@test "pal-implement happy path with mocked docker" {
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/preflight.sh"
    source "$REPO_ROOT/lib/runs.sh"
    source "$REPO_ROOT/lib/launcher.sh"

    # Stub pal_preflight_gh_auth to skip network call
    pal_preflight_gh_auth() { :; }

    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/preflight.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        pal_preflight_gh_auth() { :; }
        pal_preflight_all 'owner/repo' 42
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement sync
        pal_launch_sync \"\$run_id\" owner/repo 42 implement > /dev/null
        pal_render_status_summary \"\$run_id\"
    "
    assert_success
    assert_output --partial "success"
    assert_output --partial "https://github.com/x/y/pull/99"
}
EOF
```

- [ ] **Step 2: Run the test**

```bash
cd ~/repos/claude-pal
./tests/bats/bin/bats tests/test_skill_pal_implement.bats
```

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-pal
git add tests/test_skill_pal_implement.bats
git commit -m "test(plugin): pal-implement happy path smoke test with mocked docker"
```

**Milestone:** `/pal-implement <issue#>` works end-to-end against a real test repo (documented in Phase 2 Task 2.10) in sync mode.

---

## Phase 4: `/pal-plan` skill

### Task 4.1: Plan file locator

**Files:**
- Create: `~/repos/claude-pal/lib/plan-locator.sh`

- [ ] **Step 1: Write plan-locator.sh**

```bash
cat > ~/repos/claude-pal/lib/plan-locator.sh <<'EOF'
# lib/plan-locator.sh
# Locate the implementation plan file to publish.

pal_find_plan_file() {
    local explicit_file="${1:-}"
    if [ -n "$explicit_file" ]; then
        if [ ! -f "$explicit_file" ]; then
            echo "pal: plan file not found: $explicit_file" >&2
            return 1
        fi
        echo "$explicit_file"
        return 0
    fi

    # Auto-detect: most recent file in docs/superpowers/plans/
    local default_dir="docs/superpowers/plans"
    if [ -d "$default_dir" ]; then
        local latest
        latest=$(ls -t "$default_dir"/*.md 2>/dev/null | head -1 || true)
        if [ -n "$latest" ]; then
            echo "$latest"
            return 0
        fi
    fi

    echo "pal: could not auto-detect a plan file" >&2
    echo "pal: checked: $default_dir" >&2
    echo "pal: provide a path explicitly via: /pal-plan [issue#] --file <path>" >&2
    return 1
}
EOF
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/plan-locator.sh
cd ~/repos/claude-pal
git add lib/plan-locator.sh
git commit -m "feat(plugin): plan-locator for auto-detecting plan files"
```

### Task 4.2: Plan publisher

**Files:**
- Create: `~/repos/claude-pal/lib/publisher.sh`

- [ ] **Step 1: Write publisher.sh**

```bash
cat > ~/repos/claude-pal/lib/publisher.sh <<'EOF'
# lib/publisher.sh
# Publish a plan file as an issue comment (with <!-- agent-plan --> marker).

pal_publish_plan() {
    local plan_file="$1"
    local repo="$2"
    local issue="${3:-}"

    local plan_content
    plan_content=$(cat "$plan_file")
    local comment_body=$'<!-- agent-plan -->\n'"$plan_content"

    if [ -z "$issue" ]; then
        # Derive title from first H1 in the plan file
        local title
        title=$(awk '/^# /{sub(/^# /,""); print; exit}' "$plan_file")
        if [ -z "$title" ]; then
            title="claude-pal implementation plan ($(date -I))"
        fi

        local problem_summary="<!-- agent-plan -->
$plan_content"

        local new_issue_url
        new_issue_url=$(GH_TOKEN="$GH_TOKEN" gh issue create \
            --repo "$repo" \
            --title "$title" \
            --body "$problem_summary" \
            2>&1 | tail -1) || {
                echo "pal: failed to create issue" >&2
                return 1
            }
        issue=$(echo "$new_issue_url" | grep -Eo '/issues/[0-9]+' | grep -Eo '[0-9]+')
        echo "Created new issue: $new_issue_url"
    else
        local comment_url
        comment_url=$(GH_TOKEN="$GH_TOKEN" gh issue comment "$issue" \
            --repo "$repo" \
            --body "$comment_body" 2>&1 | tail -1) || {
                echo "pal: failed to post comment on issue $issue" >&2
                return 1
            }
        echo "Posted plan comment: $comment_url"
    fi

    echo ""
    echo "Next step:"
    echo "  /pal-implement $issue"
}
EOF
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/publisher.sh
cd ~/repos/claude-pal
git add lib/publisher.sh
git commit -m "feat(plugin): plan publisher (new issue or comment on existing)"
```

### Task 4.3: `/pal-plan` skill markdown

**Files:**
- Create: `~/repos/claude-pal/skills/pal-plan/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

```bash
mkdir -p ~/repos/claude-pal/skills/pal-plan
cat > ~/repos/claude-pal/skills/pal-plan/SKILL.md <<'EOF'
---
name: pal-plan
description: Publish an implementation plan from the current conversation to a GitHub issue. Takes the most recent plan file in docs/superpowers/plans/ (or an explicit --file path) and posts it as a comment with <!-- agent-plan --> marker. Creates a new issue if no issue number given. Does NOT launch a container — provides a checkpoint to review the posted plan on GitHub before running /pal-implement.
---

# pal-plan

Publish a plan to GitHub for later dispatch.

## Usage

```
/pal-plan [issue#] [--file <path>]
```

## Steps

1. Parse arguments: zero or one positional issue number; optional `--file <path>`.
2. Source shared libs (Claude Code sets `${CLAUDE_PLUGIN_ROOT}` when the skill fires):
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/plan-locator.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/publisher.sh"
   ```
3. Load config: `pal_load_config`.
4. Locate the plan file: `plan_file=$(pal_find_plan_file "$file_arg")`. On failure, exit with the locator's error.
5. Determine target repo from cwd's git origin, or require `PAL_REPO` env var.
6. Publish: `pal_publish_plan "$plan_file" "$repo" "$issue_arg"`.
7. The publisher prints the issue URL and a "Next step: /pal-implement <issue#>" hint.

## Examples

- `/pal-plan` — auto-detect latest plan, create a new issue with it
- `/pal-plan 42` — auto-detect latest plan, post as comment on issue #42
- `/pal-plan 42 --file docs/superpowers/plans/2026-04-18-feature.md` — post a specific plan on issue #42
EOF
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add skills/pal-plan/SKILL.md
git commit -m "feat(plugin): pal-plan SKILL.md"
```

### Task 4.4: `/pal-plan` smoke test

**Files:**
- Create: `~/repos/claude-pal/tests/test_skill_pal_plan.bats`

- [ ] **Step 1: Write the test (mocks gh CLI)**

```bash
cat > ~/repos/claude-pal/tests/test_skill_pal_plan.bats <<'EOF'
#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export GH_TOKEN="fake"
    mkdir -p "$XDG_CONFIG_HOME/claude-pal"
    cat > "$XDG_CONFIG_HOME/claude-pal/config.env" <<CONFIG
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake
GH_TOKEN=github_pat_fake
CONFIG
    chmod 600 "$XDG_CONFIG_HOME/claude-pal/config.env"

    # Fake project with a plan file
    WORKDIR="$(mktemp -d)"
    mkdir -p "$WORKDIR/docs/superpowers/plans"
    cat > "$WORKDIR/docs/superpowers/plans/2026-04-18-feature.md" <<PLAN
# Test Plan
This is a test plan.
PLAN

    # Mock gh
    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"
    cat > "$TMPHOME/bin/gh" <<'GH_MOCK'
#!/bin/bash
case "$1 $2" in
    "issue create")
        echo "https://github.com/owner/repo/issues/123"
        exit 0
        ;;
    "issue comment")
        echo "https://github.com/owner/repo/issues/42#issuecomment-99"
        exit 0
        ;;
esac
exit 1
GH_MOCK
    chmod +x "$TMPHOME/bin/gh"
}

teardown() {
    rm -rf "$TMPHOME" "$WORKDIR"
}

@test "pal-plan with existing issue posts a comment" {
    cd "$WORKDIR"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/plan-locator.sh"
    source "$REPO_ROOT/lib/publisher.sh"
    pal_load_config
    plan=$(pal_find_plan_file)

    run pal_publish_plan "$plan" owner/repo 42
    assert_success
    assert_output --partial "Posted plan comment"
    assert_output --partial "/pal-implement 42"
}

@test "pal-plan without issue creates a new one" {
    cd "$WORKDIR"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/plan-locator.sh"
    source "$REPO_ROOT/lib/publisher.sh"
    pal_load_config
    plan=$(pal_find_plan_file)

    run pal_publish_plan "$plan" owner/repo ""
    assert_success
    assert_output --partial "Created new issue"
    assert_output --partial "/pal-implement 123"
}
EOF
```

- [ ] **Step 2: Run the tests**

```bash
cd ~/repos/claude-pal
./tests/bats/bin/bats tests/test_skill_pal_plan.bats
```

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-pal
git add tests/test_skill_pal_plan.bats
git commit -m "test(plugin): pal-plan coverage for new-issue and existing-issue flows"
```

### Task 4.5: `/pal-brainstorm` orchestrator command

Adds an optional entry-point slash command for the full ideation → PR flow. Depends on the `superpowers` plugin (soft check — falls back to a user-facing install hint if missing). Also tightens the `description` fields on `pal-plan` and `pal-implement` so Claude's natural-language skill-selector can match on phrases like "help me plan an issue", "have pal build this", etc.

**Files:**
- Create: `~/repos/claude-pal/commands/pal-brainstorm.md`
- Edit: `~/repos/claude-pal/skills/pal-plan/SKILL.md` (description only)
- Edit: `~/repos/claude-pal/skills/pal-implement/SKILL.md` (description only)

**Background / design rationale** (so future-me doesn't relitigate):
- Plugin commands live at `commands/<name>.md` at plugin root (not under `.claude-plugin/`).
- Plugin skills/commands invoke as `/<plugin-name>:<name>` — so this one is `/claude-pal:pal-brainstorm`. Short form (`/pal-brainstorm`) only works for standalone skills, not plugins.
- Explicit slash invocation is the reliable path; natural-language invocation is supported but fragile per known Claude Code limitations (see GitHub issue #10768 era). Sharp `Use when ...` descriptions raise the NL hit rate but don't make it deterministic, which is why the explicit command exists.
- No `dependencies`/`requires` field in `plugin.json`. Dependency on `superpowers` is communicated in-prompt and via README; Claude can't programmatically check installed plugins, so the "superpowers missing" fallback is soft-gated through the command body.

- [ ] **Step 1: Write the command file**

```bash
mkdir -p ~/repos/claude-pal/commands
cat > ~/repos/claude-pal/commands/pal-brainstorm.md <<'EOF'
---
description: Use when the user wants to go from an idea to a pull request with pal — orchestrates the full flow (brainstorm → plan → publish → dispatch). Use when user says "plan an issue for pal", "have pal build this", "help me get pal to work on a feature", "brainstorm something for pal to implement", or similar. Depends on the superpowers plugin for the brainstorm and plan-writing steps.
---

# pal-brainstorm

Guide the user from an idea to a dispatched pal run that opens a PR.

**User's seed idea (may be empty):** $ARGUMENTS

## Prerequisite check

This flow depends on the `superpowers` plugin (provides `brainstorming` and `writing-plans` skills). If those skills are not listed in your current session's available skills, stop and tell the user:

> The /claude-pal:pal-brainstorm flow uses skills from the `superpowers` plugin. Install it from the `claude-plugins-official` marketplace, then run /claude-pal:pal-brainstorm again.

Do not attempt to proceed past this check if `superpowers:brainstorming` or `superpowers:writing-plans` are unavailable.

## Flow

1. **Brainstorm.** Invoke `superpowers:brainstorming` with the user's seed idea ($ARGUMENTS) to explore intent, requirements, and design. Let the brainstorming skill drive — don't short-circuit it.
2. **Write the plan.** Once the brainstorm converges, invoke `superpowers:writing-plans` to produce an implementation plan file under `docs/superpowers/plans/`.
3. **Checkpoint.** Show the user the plan file path and ask them to confirm before publishing to GitHub. If they want revisions, loop back to writing-plans.
4. **Publish.** Invoke the `pal-plan` skill (or `/claude-pal:pal-plan`) to post the plan as a GitHub issue comment. If the user hasn't named an existing issue, pal-plan will create a new one. Share the resulting issue URL with the user.
5. **Confirm.** Ask the user to review the posted plan on GitHub and confirm before dispatching. Offer to run /claude-pal:pal-implement in sync or async mode.
6. **Implement.** Invoke the `pal-implement` skill (or `/claude-pal:pal-implement <issue#>`) with `--async` if the user requested background execution. Otherwise run sync and stream the status to the user.

## Stopping points

Stop and ask the user between steps if:
- The brainstorm hasn't converged on concrete requirements.
- The generated plan looks too large or ambiguous to hand off to pal.
- The issue body needs manual edits on GitHub before dispatch.

Do not combine steps or skip the checkpoint before publishing — review is the point.
EOF
```

- [ ] **Step 2: Sharpen pal-plan's description for NL invocation**

Edit the `description:` field in `~/repos/claude-pal/skills/pal-plan/SKILL.md` so Claude's skill-selector matches natural phrasing. Keep the body unchanged.

New description:

```
description: Use when the user wants to publish an implementation plan to GitHub for pal to pick up. Takes the most recent plan file in docs/superpowers/plans/ (or an explicit --file path) and posts it as an issue comment with <!-- agent-plan --> marker. Creates a new issue if no issue number given. Use when user says "publish this plan", "post the plan to GitHub", "create an issue for pal", or has a plan file ready and wants pal to see it. Does NOT launch a container — it's a checkpoint before /claude-pal:pal-implement.
```

- [ ] **Step 3: Sharpen pal-implement's description for NL invocation**

Edit the `description:` field in `~/repos/claude-pal/skills/pal-implement/SKILL.md`:

```
description: Use when the user wants pal to actually start working on a GitHub issue. Launches an ephemeral Docker container that reads the plan from the issue and runs a gated pipeline (adversarial plan review → TDD implementation → post-impl review → opens PR). Use when user says "have pal implement this", "kick off pal on issue #N", "dispatch pal", "run the pal container on this issue", or similar. Sync by default; pass --async to background.
```

- [ ] **Step 4: Validate manifest and run tests**

```bash
claude plugin validate ~/repos/claude-pal
cd ~/repos/claude-pal
./tests/bats/bin/bats tests/
shellcheck lib/*.sh image/opt/pal/lib/*.sh image/opt/pal/entrypoint.sh
```

All three must pass. No new bats test for the command itself — commands are markdown prompts, not shell code, and their behavior is model-executed rather than deterministic. Coverage for the underlying skills (`pal-plan`, `pal-implement`) already exists.

- [ ] **Step 5: Commit**

```bash
cd ~/repos/claude-pal
git add commands/pal-brainstorm.md skills/pal-plan/SKILL.md skills/pal-implement/SKILL.md
git commit -m "feat(plugin): pal-brainstorm orchestrator command + sharpen NL descriptions"
```

**Milestone:** Three user-visible entry points now exist — `/claude-pal:pal-brainstorm` (full flow), `/claude-pal:pal-plan` (publish a pre-written plan), `/claude-pal:pal-implement` (dispatch on an existing issue). Descriptions on the two skills are tuned for natural-language invocation so the typical interaction is "have pal build this" rather than explicit slash typing.

### Task 4.6: Pivot to env-passthrough auth (no on-disk secrets file)

**Context / rationale** (so the design decision is recorded).

Prior design stored credentials in a 0600 `~/.config/claude-pal/config.env` that `pal_load_config` read from disk. Research during Phase 4 (see conversation notes + `anthropics/claude-code-action` docs, [The New Stack's Agent SDK interview](https://thenewstack.io/anthropic-agent-sdk-confusion/), and the Anthropic [Usage Policy update](https://www.anthropic.com/news/usage-policy-update)) surfaced two material issues:

1. **ToS positioning.** Anthropic's Feb 2026 Consumer ToS clarification prohibits using subscription OAuth tokens in third-party tools. A personal-use carveout exists (public Anthropic employee statement). The carveout is clearest when the tool follows the documented env-var pattern used by `anthropics/claude-code-action` (export → `docker run -e`), rather than maintaining its own credential file.
2. **Duplication / attack surface.** A plugin-managed 0600 file duplicates what the user already has to maintain in their shell profile for any other CLI (`gh`, `aws`, etc.). Surveyed community tooling (koogle/claudebox, textcortex/claude-code-sandbox, anthropics/claude-code-action, boxlite-ai/claudebox) overwhelmingly uses env passthrough + optional OS-native credential store, not a bespoke config file.

**Redesign:** claude-pal reads `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` / `GH_TOKEN` from `$ENV` directly. No plugin-managed file. Users wire the exports into their shell profile once (or inherit from CI secrets). Phase 7 (keychain/Credential-Manager/pass) is deferred as future nice-to-have, since env-passthrough covers the canonical case and matches industry norms.

**Files:**
- Rewrite: `~/repos/claude-pal/lib/config.sh` — no file IO; assert required env vars only
- Edit: `~/repos/claude-pal/lib/preflight.sh` — drop `pal_config_permissions_ok` + `pal_preflight_no_api_key_in_env`; keep single-auth-method check; update messages to reference env vars
- Edit: `~/repos/claude-pal/tests/test_skill_pal_plan.bats` — `export` env vars instead of writing `config.env`
- Edit: `~/repos/claude-pal/tests/test_skill_pal_implement.bats` — same
- Create: `~/repos/claude-pal/commands/pal-setup.md` — guided walkthrough (prompts for credential type, generates OAuth token via `claude setup-token`, adds exports to shell profile, verifies)
- Edit: `~/repos/claude-pal/README.md` — authentication section with one-time setup, OAuth vs API key guidance, ToS note
- Edit: `~/repos/claude-pal/CLAUDE.md` — record the env-passthrough architecture so future sessions don't reinvent the file-based approach
- Edit: `~/repos/claude-pal/docs/superpowers/plans/2026-04-18-claude-pal.md` — mark Phase 7 deferred (this task)

**Steps:**

- [ ] **Step 1: Rewrite `lib/config.sh`**

Replace the file with:

```bash
# lib/config.sh
# shellcheck shell=bash
# Verify required credentials are present in the process environment.
#
# claude-pal uses env-passthrough exclusively — this matches Anthropic's own
# anthropics/claude-code-action pattern. No on-disk secret file: users
# export CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY) and GH_TOKEN in
# their shell profile once, and claude-pal forwards them to the container.

pal_load_config() {
    local missing=()
    [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] \
        && missing+=("CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY)")
    [ -z "${GH_TOKEN:-}" ] && missing+=("GH_TOKEN")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "pal: missing required environment variable(s): ${missing[*]}" >&2
        echo "pal: one-time setup: claude setup-token, then export CLAUDE_CODE_OAUTH_TOKEN=... and GH_TOKEN=... in ~/.bashrc" >&2
        echo "pal: or: /claude-pal:pal-setup for a guided walkthrough" >&2
        return 1
    fi
}
```

Drop `pal_config_path` and `pal_config_permissions_ok` — both were file-scoped helpers with no purpose under env-passthrough.

- [ ] **Step 2: Edit `lib/preflight.sh`**

Remove `pal_preflight_no_api_key_in_env` entirely (was a "don't let env shadow config.env" guard that no longer applies). Keep `pal_preflight_single_auth_method` but reword errors to talk about env vars, not `config.env`. Drop the `pal_config_permissions_ok` call from `pal_preflight_all`. `pal_preflight_gh_auth` no longer needs its own GH_TOKEN-missing check since `pal_load_config` covers it.

- [ ] **Step 3: Update bats tests**

In `tests/test_skill_pal_plan.bats` and `tests/test_skill_pal_implement.bats` setup, replace the `config.env` write + `chmod 600` block with:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake
export GH_TOKEN=github_pat_fake
unset ANTHROPIC_API_KEY
```

Keep the `HOME=$TMPHOME` / `XDG_*` redirection as defensive isolation.

- [ ] **Step 4: Create `commands/pal-setup.md`**

Frontmatter description tuned for NL invocation ("missing required environment variable", "how do I set up pal", "configure claude-pal"). Body walks through: detect current env state, pick credential type, detect shell, run `claude setup-token`, emit `export` lines to the right profile file, verify with a preflight snippet. Include a ToS reminder at the bottom.

- [ ] **Step 5: Update `README.md` and `CLAUDE.md`**

README: authentication section explaining env-passthrough, one-time setup, OAuth-vs-API-key guidance, ToS note, and plugin entry points. CLAUDE.md: "Authentication model" heading that documents env-passthrough so future Claude sessions don't reintroduce a file-based loader.

- [ ] **Step 6: Defer Phase 7**

Prepend a `**Status (2026-04-19):** Deferred...` note to Phase 7's heading in this plan doc. Keep the original tasks intact for reference.

- [ ] **Step 7: Verify and commit**

```bash
claude plugin validate ~/repos/claude-pal
cd ~/repos/claude-pal
./tests/bats/bin/bats tests/
shellcheck lib/*.sh image/opt/pal/lib/*.sh image/opt/pal/entrypoint.sh
```

All three green. Then commit in two logical chunks:

```bash
git add lib/config.sh lib/preflight.sh tests/test_skill_pal_plan.bats tests/test_skill_pal_implement.bats
git commit -m "refactor(plugin): pivot auth to env-passthrough (no config.env)"

git add commands/pal-setup.md README.md CLAUDE.md docs/superpowers/plans/2026-04-18-claude-pal.md
git commit -m "feat(plugin): pal-setup walkthrough + auth docs + defer Phase 7"
```

**Milestone:** Auth model is aligned with Anthropic's documented pattern. Users run `claude setup-token` + add two `export` lines to their shell profile (or use `/claude-pal:pal-setup`) and they're ready to dispatch. No on-disk secrets managed by the plugin. Phase 7's OS-native credential integrations remain available as a future option if the design ever needs to go back to file storage.

---

## Phase 5: Async mode, run registry management, and support skills — **COMPLETE**

**Sequencing note (2026-04-19, updated):** Phases 5, 6, and 8 complete. All 5 BATS tests pass. Current HEAD: `b10088f`.

---

### Task 5.1: Cross-platform notifier

**Files:**
- Create: `~/repos/claude-pal/lib/notify.sh`

- [x] **Step 1: Write notify.sh**

```bash
cat > ~/repos/claude-pal/lib/notify.sh <<'EOF'
# lib/notify.sh
# Cross-platform desktop notifier.

pal_notify() {
    local title="${1:-claude-pal}"
    local message="$2"

    # Honor override
    if [ -n "${PAL_NOTIFY_COMMAND_OVERRIDE:-}" ]; then
        "$PAL_NOTIFY_COMMAND_OVERRIDE" "$title" "$message" && return 0
    fi

    # Respect disable flag
    if [ "${PAL_NOTIFY:-true}" != "true" ]; then
        return 0
    fi

    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux)
            if command -v notify-send > /dev/null 2>&1; then
                notify-send "$title" "$message" || true
            fi
            ;;
        Darwin)
            osascript -e "display notification \"$(printf '%s' "$message" | sed 's/"/\\"/g')\" with title \"$title\"" 2>/dev/null || true
            ;;
        MINGW*|MSYS*|CYGWIN*)
            if command -v powershell.exe > /dev/null 2>&1; then
                powershell.exe -NoProfile -Command "
                    try {
                        Import-Module BurntToast -ErrorAction Stop
                        New-BurntToastNotification -Text '$title', '$(printf '%s' "$message" | sed "s/'/''/g")'
                    } catch {
                        Write-Host 'pal-notify: BurntToast module not installed (Install-Module BurntToast)'
                    }
                " 2>/dev/null || true
            fi
            ;;
    esac
}
EOF
```

- [x] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/notify.sh
cd ~/repos/claude-pal
git add lib/notify.sh
git commit -m "feat(skills): cross-platform desktop notifier (Linux/macOS/Windows)"
```

### Task 5.2: Async launcher with watcher

**Files:**
- Modify: `~/repos/claude-pal/lib/launcher.sh`

- [x] **Step 1: Add async launch function to launcher.sh**

Append to `lib/launcher.sh`:

```bash

pal_launch_async() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local event_type="$4"

    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local image_tag="${PAL_IMAGE_TAG:-claude-pal:latest}"

    local per_repo_config=".pal/config.env"
    local per_repo_args=()
    if [ -f "$per_repo_config" ]; then
        local per_repo_env
        per_repo_env=$(grep -E '^(AGENT_|PAL_|DOCKER_HOST=)' "$per_repo_config" | grep -v '^#' || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            per_repo_args+=(-e "$line")
        done <<< "$per_repo_env"
    fi

    local docker_args=(
        run --rm --detach
        --cap-add=NET_ADMIN
        -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
        -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
        -e GH_TOKEN="$GH_TOKEN"
        -v "$run_dir:/status"
    )
    docker_args+=("${per_repo_args[@]}")
    docker_args+=("$image_tag" "$event_type" "$repo" "$number")

    pal_acquire_lock "$run_id" "$repo" "$number"

    local cid
    cid=$(docker "${docker_args[@]}")
    echo "$cid" > "$run_dir/container_id"

    # Fork watcher: wait for container exit, then notify
    (
        source "$(dirname "${BASH_SOURCE[0]}")/notify.sh"
        source "$(dirname "${BASH_SOURCE[0]}")/runs.sh"
        docker wait "$cid" > /dev/null 2>&1 || true
        # Harvest final logs (best-effort)
        docker logs "$cid" > "$run_dir/log" 2>&1 || true
        # Release lock
        pal_release_lock "$repo" "$number"
        # Read status and notify
        if [ -f "$run_dir/status.json" ]; then
            local outcome pr_url
            outcome=$(jq -r .outcome "$run_dir/status.json" 2>/dev/null)
            pr_url=$(jq -r .pr_url "$run_dir/status.json" 2>/dev/null)
            case "$outcome" in
                success)
                    pal_notify "claude-pal: $run_id complete" "PR: $pr_url"
                    ;;
                *)
                    pal_notify "claude-pal: $run_id $outcome" "Check /pal-status $run_id"
                    ;;
            esac
        else
            pal_notify "claude-pal: $run_id exited" "No status.json — check /pal-logs $run_id"
        fi
    ) &

    echo "Run $run_id launched (async, container $cid)"
    echo "  Status: /pal-status $run_id"
    echo "  Logs:   /pal-logs $run_id --follow"
}
```

- [x] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/launcher.sh
cd ~/repos/claude-pal
git add lib/launcher.sh
git commit -m "feat(skills): async launcher with forked watcher and notification"
```

### Task 5.3: Wire --async into `/pal-implement`

**Files:**
- Modify: `~/repos/claude-pal/skills/pal-implement/SKILL.md`

- [x] **Step 1: Update SKILL.md to handle --async**

Update the "Steps" section to:

```markdown
7. If `--async` flag given:
   - `pal_launch_async "$run_id" "$repo" "$issue_num" "implement"`
   - Return immediately; skip status summary step.
   Otherwise:
   - `pal_launch_sync "$run_id" "$repo" "$issue_num" "implement"` (exit code propagates)
   - `pal_render_status_summary "$run_id"`
```

- [x] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add skills/pal-implement/SKILL.md
git commit -m "feat(skills): pal-implement now supports --async"
```

### Task 5.4: `/pal-status` skill

**Files:**
- Create: `~/repos/claude-pal/skills/pal-status/SKILL.md`
- Create: `~/repos/claude-pal/lib/status-list.sh`

- [x] **Step 1: Write status-list.sh**

```bash
mkdir -p ~/repos/claude-pal/skills/pal-status
cat > ~/repos/claude-pal/lib/status-list.sh <<'EOF'
# lib/status-list.sh
# List runs and reconcile against docker ps.

pal_list_runs() {
    local runs_dir
    runs_dir=$(pal_runs_dir)
    [ ! -d "$runs_dir" ] && { echo "No runs yet."; return 0; }

    printf '%-32s %-10s %-32s %-10s\n' "RUN_ID" "STATE" "REPO#NUMBER" "OUTCOME"
    printf '%-32s %-10s %-32s %-10s\n' "--------------------------------" "----------" "--------------------------------" "----------"

    for rd in "$runs_dir"/*/; do
        [ ! -d "$rd" ] && continue
        local run_id
        run_id=$(basename "$rd")
        local meta="$rd/launch_meta.json"
        local status="$rd/status.json"
        local cid_file="$rd/container_id"

        local repo number event_type started_at
        if [ -f "$meta" ]; then
            repo=$(jq -r .repo "$meta")
            number=$(jq -r '.issue_number // .pr_number' "$meta")
            event_type=$(jq -r .event_type "$meta")
        else
            repo="?"; number="?"; event_type="?"
        fi

        local state outcome
        if [ -f "$status" ]; then
            state="complete"
            outcome=$(jq -r .outcome "$status")
        elif [ -f "$cid_file" ]; then
            local cid
            cid=$(cat "$cid_file")
            if docker ps --filter "id=$cid" --format '{{.ID}}' 2>/dev/null | grep -q .; then
                state="running"
                outcome="-"
            else
                # Container gone but no status.json — reconcile as stale
                state="stale"
                outcome="unknown"
            fi
        else
            state="abandoned"
            outcome="-"
        fi

        printf '%-32s %-10s %-32s %-10s\n' "$run_id" "$state" "${repo}#${number}" "$outcome"
    done
}

pal_show_run() {
    local run_id="$1"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    [ ! -d "$run_dir" ] && { echo "pal: no such run: $run_id" >&2; return 1; }

    echo "=== Launch metadata ==="
    [ -f "$run_dir/launch_meta.json" ] && jq . "$run_dir/launch_meta.json"
    echo ""
    echo "=== Status ==="
    if [ -f "$run_dir/status.json" ]; then
        jq . "$run_dir/status.json"
    else
        echo "(no status.json yet — run may be in flight)"
    fi
    echo ""
    echo "Log: $run_dir/log"
}

pal_clean_runs() {
    local runs_dir
    runs_dir=$(pal_runs_dir)
    [ ! -d "$runs_dir" ] && return 0

    local cutoff_days="${1:-30}"
    local removed=0
    for rd in "$runs_dir"/*/; do
        [ ! -d "$rd" ] && continue
        if [ "$(find "$rd" -maxdepth 0 -mtime +"$cutoff_days" -print)" ]; then
            rm -rf "$rd"
            removed=$((removed+1))
        fi
    done
    echo "Removed $removed runs older than $cutoff_days days."
}
EOF
```

- [x] **Step 2: Write `/pal-status` SKILL.md**

```bash
cat > ~/repos/claude-pal/skills/pal-status/SKILL.md <<'EOF'
---
name: pal-status
description: List claude-pal runs or show details on a specific one. Reconciles stale status against docker ps.
---

# pal-status

## Usage

```
/pal-status [run_id] [--clean [days]]
```

## Steps

1. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/status-list.sh"
   ```
2. If `--clean` given: `pal_clean_runs "${days:-30}"`. Exit.
3. If `run_id` given: `pal_show_run "$run_id"`.
4. Otherwise: `pal_list_runs`.
EOF
```

- [x] **Step 3: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/status-list.sh
cd ~/repos/claude-pal
git add lib/status-list.sh skills/pal-status/SKILL.md
git commit -m "feat(plugin): pal-status for listing/detailing/cleaning runs"
```

### Task 5.5: `/pal-logs` skill

**Files:**
- Create: `~/repos/claude-pal/skills/pal-logs/SKILL.md`

- [x] **Step 1: Write SKILL.md**

```bash
mkdir -p ~/repos/claude-pal/skills/pal-logs
cat > ~/repos/claude-pal/skills/pal-logs/SKILL.md <<'EOF'
---
name: pal-logs
description: Tail logs for a claude-pal run. Supports --follow to stream live output.
---

# pal-logs

## Usage

```
/pal-logs <run_id> [--follow]
```

## Steps

1. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   ```
2. Compute `log_file="$(pal_run_dir "$run_id")/log"`.
3. If file does not exist, report error and exit 1.
4. If `--follow` flag given: `tail -f "$log_file"`.
5. Else: `cat "$log_file"`.
EOF
```

- [x] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add skills/pal-logs/SKILL.md
git commit -m "feat(plugin): pal-logs skill"
```

### Task 5.6: `/pal-cancel` skill

**Files:**
- Create: `~/repos/claude-pal/skills/pal-cancel/SKILL.md`
- Modify: `~/repos/claude-pal/lib/launcher.sh`

- [x] **Step 1: Add pal_cancel to launcher.sh**

Append to `lib/launcher.sh`:

```bash

pal_cancel_run() {
    local run_id="$1"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local cid_file="$run_dir/container_id"

    if [ ! -f "$cid_file" ]; then
        echo "pal: no container_id recorded for run $run_id" >&2
        return 1
    fi

    local cid
    cid=$(cat "$cid_file")

    if ! docker ps --filter "id=$cid" --format '{{.ID}}' 2>/dev/null | grep -q .; then
        echo "pal: container $cid not running" >&2
        return 1
    fi

    echo "pal: sending SIGTERM to $cid (grace 10s)"
    docker stop --time 10 "$cid" > /dev/null || true

    # Write a cancelled status
    cat > "$run_dir/status.json" <<EOF_CANCEL
{
  "phase": "cancelled",
  "outcome": "cancelled",
  "failure_reason": "user_cancelled",
  "pr_number": null,
  "pr_url": null,
  "commits": [],
  "review_concerns_addressed": [],
  "review_concerns_unresolved": []
}
EOF_CANCEL

    # Release lock if meta exists
    if [ -f "$run_dir/launch_meta.json" ]; then
        local repo number
        repo=$(jq -r .repo "$run_dir/launch_meta.json")
        number=$(jq -r '.issue_number // .pr_number' "$run_dir/launch_meta.json")
        pal_release_lock "$repo" "$number"
    fi

    echo "pal: run $run_id cancelled"
}
```

- [x] **Step 2: Write SKILL.md**

```bash
mkdir -p ~/repos/claude-pal/skills/pal-cancel
cat > ~/repos/claude-pal/skills/pal-cancel/SKILL.md <<'EOF'
---
name: pal-cancel
description: Cancel an in-flight claude-pal run. Sends SIGTERM (10s grace) then SIGKILL.
---

# pal-cancel

## Usage

```
/pal-cancel <run_id>
```

## Steps

1. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
2. Call `pal_cancel_run "$run_id"`.
EOF
```

- [x] **Step 3: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/launcher.sh
cd ~/repos/claude-pal
git add skills/pal-cancel/SKILL.md lib/launcher.sh
git commit -m "feat(plugin): pal-cancel for killing in-flight runs"
```

**Milestone:** All run-lifecycle skills (`/pal-status`, `/pal-logs`, `/pal-cancel`) work; `/pal-implement --async` queues runs in the background with desktop notifications on completion.

---

## Phase 6: `/pal-revise` skill — **COMPLETE**

**Sequencing note (2026-04-19):** Phase 6 complete. All phases complete except Phase 7 (deferred) and Phase 8 (already done). Current HEAD: `b10088f`.

---

### Task 6.1: `/pal-revise` skill markdown

**Files:**
- Create: `~/repos/claude-pal/skills/pal-revise/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

```bash
mkdir -p ~/repos/claude-pal/skills/pal-revise
cat > ~/repos/claude-pal/skills/pal-revise/SKILL.md <<'EOF'
---
name: pal-revise
description: Launch an ephemeral Docker container to address PR review feedback. Fetches PR branch and review comments, runs a focused implementation pass to address concerns, pushes new commits to the PR.
---

# pal-revise

## Usage

```
/pal-revise <pr#> [--async]
```

## Steps

1. Parse: exactly one positional PR number; optional `--async`.
2. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/preflight.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
3. Determine repo from cwd git origin or `PAL_REPO`.
4. Run `pal_preflight_all "$repo" "$pr_num"`.
5. Generate run id and write launch meta: `pal_write_launch_meta "$run_id" "$repo" "$pr_num" "revise" "$mode"`.
6. Launch (sync or async based on flag): passes `revise` as the event_type to the container.
7. Container:
   - Fetches PR branch (via Task 2.3's `setup_worktree` revise path)
   - Fetches PR review feedback (via Task 2.4's `fetch_pr_context`)
   - Skips adversarial plan review
   - Runs an implement pass with `AGENT_REVIEW_CONCERNS` set from review feedback
   - Runs test gate + post-impl review
   - Pushes new commits to the existing PR branch (no new PR)
8. Sync mode prints status summary. Async mode fires desktop notification on completion.

## Examples

- `/pal-revise 317` — address feedback on PR #317 synchronously
- `/pal-revise 317 --async` — same, in background
EOF
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add skills/pal-revise/SKILL.md
git commit -m "feat(plugin): pal-revise SKILL.md"
```

### Task 6.2: End-to-end revise test

**Files:**
- Create: `~/repos/claude-pal/tests/test_revise_smoke.bats`

- [ ] **Step 1: Write the test**

```bash
cat > ~/repos/claude-pal/tests/test_revise_smoke.bats <<'EOF'
#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# This test requires a real PR with review feedback. Skips if envs missing.

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    : "${PAL_TEST_REPO:?set PAL_TEST_REPO}"
    : "${PAL_TEST_PR_WITH_REVIEW:?set PAL_TEST_PR_WITH_REVIEW to a PR# with CHANGES_REQUESTED review}"
    : "${CLAUDE_CODE_OAUTH_TOKEN:?}"
    : "${GH_TOKEN:?}"
    IMAGE_TAG="claude-pal:test-revise-$RANDOM"
    STATUS_DIR="$(mktemp -d)"
}

teardown() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" 2>/dev/null || true
    [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
}

@test "revise pipeline round-trips on smoketest PR" {
    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1

    run docker run --rm \
        --cap-add=NET_ADMIN \
        -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        -e GH_TOKEN="$GH_TOKEN" \
        -v "$STATUS_DIR:/status" \
        "$IMAGE_TAG" revise "$PAL_TEST_REPO" "$PAL_TEST_PR_WITH_REVIEW"
    assert_success

    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
}
EOF
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add tests/test_revise_smoke.bats
git commit -m "test(container): end-to-end revise pipeline test"
```

**Milestone:** `/pal-revise <pr#>` addresses review feedback and pushes new commits.

---

## Phase 7: Cross-platform hardening — **DEFERRED**

**Status (2026-04-19):** Deferred as "future nice-to-have." Task 4.6 pivoted claude-pal to env-passthrough (credentials read from the process environment, not a plugin-managed file), which matches Anthropic's own `anthropics/claude-code-action` pattern. The original driver for Phase 7 — a 0600 `config.env` on disk that would benefit from OS-native credential stores — no longer exists. Users today export `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` and `GH_TOKEN` in their shell profile once; the plugin reads from `$ENV` at dispatch time. Shell-profile storage is functionally equivalent to `~/.aws/credentials` or `~/.config/gh/hosts.yml`, which the industry accepts as a default.

The tasks below are kept for reference in case claude-pal later reintroduces a file-based credential path or becomes distributable as a multi-user service. Do not execute them unless that design change happens first.

### Task 7.1: macOS Keychain loader

**Files:**
- Modify: `~/repos/claude-pal/lib/config.sh`

- [ ] **Step 1: Add Keychain helpers**

Append to `lib/config.sh`:

```bash

pal_try_macos_keychain() {
    [ "$(uname -s)" != "Darwin" ] && return 1

    local oauth
    oauth=$(security find-generic-password -a "$USER" -s claude-pal-oauth -w 2>/dev/null) || return 1
    if [ -n "$oauth" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$oauth"
        return 0
    fi
    return 1
}
```

And in `pal_load_config`, before the final sourcing, try the Keychain first:

```bash
pal_load_config() {
    # Try platform-specific keychain first (hardening)
    if pal_try_macos_keychain 2>/dev/null; then
        # Keychain provided the token; still source config.env for GH_TOKEN etc.
        local path
        path=$(pal_config_path)
        if [ -f "$path" ]; then
            # shellcheck source=/dev/null
            . "$path"
        fi
        return 0
    fi

    # Fallback to file-only
    local path
    path=$(pal_config_path)
    if [ ! -f "$path" ]; then
        echo "pal: config file not found at $path" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "$path"
}
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/config.sh
cd ~/repos/claude-pal
git add lib/config.sh
git commit -m "feat(skills): auto-detect macOS Keychain-stored OAuth token"
```

### Task 7.2: Windows Credential Manager loader

**Files:**
- Modify: `~/repos/claude-pal/lib/config.sh`

- [ ] **Step 1: Add Windows Credential Manager helper**

Append to `lib/config.sh`:

```bash

pal_try_windows_credential_manager() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) return 1 ;;
    esac

    local oauth
    oauth=$(powershell.exe -NoProfile -Command "
        try {
            \$cred = Get-StoredCredential -Target 'claude-pal-oauth' -ErrorAction Stop
            [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(\$cred.Password))
        } catch { '' }
    " 2>/dev/null | tr -d '\r\n') || return 1

    if [ -n "$oauth" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$oauth"
        return 0
    fi
    return 1
}
```

Update `pal_load_config` to also try Windows Credential Manager before falling through to file:

```bash
pal_load_config() {
    if pal_try_macos_keychain 2>/dev/null || pal_try_windows_credential_manager 2>/dev/null; then
        local path
        path=$(pal_config_path)
        [ -f "$path" ] && . "$path"
        return 0
    fi

    local path
    path=$(pal_config_path)
    if [ ! -f "$path" ]; then
        echo "pal: config file not found at $path" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "$path"
}
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/config.sh
cd ~/repos/claude-pal
git add lib/config.sh
git commit -m "feat(skills): auto-detect Windows Credential Manager OAuth token"
```

### Task 7.3: Linux `pass` opt-in integration

**Files:**
- Modify: `~/repos/claude-pal/lib/config.sh`

- [ ] **Step 1: Add pass support via PAL_CRED_SOURCE env**

Append to `lib/config.sh`:

```bash

pal_try_pass_source() {
    [ -z "${PAL_CRED_SOURCE:-}" ] && return 1
    case "$PAL_CRED_SOURCE" in
        pass:*)
            local pass_path="${PAL_CRED_SOURCE#pass:}"
            if ! command -v pass > /dev/null 2>&1; then
                echo "pal: PAL_CRED_SOURCE uses pass but the 'pass' command is not installed" >&2
                return 1
            fi
            local oauth
            oauth=$(pass show "$pass_path" 2>/dev/null) || return 1
            export CLAUDE_CODE_OAUTH_TOKEN="$oauth"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
```

Add this to `pal_load_config`'s try chain:

```bash
pal_load_config() {
    if pal_try_macos_keychain 2>/dev/null || pal_try_windows_credential_manager 2>/dev/null || pal_try_pass_source 2>/dev/null; then
        local path
        path=$(pal_config_path)
        [ -f "$path" ] && . "$path"
        return 0
    fi
    # ... (rest unchanged)
}
```

- [ ] **Step 2: shellcheck and commit**

```bash
shellcheck ~/repos/claude-pal/lib/config.sh
cd ~/repos/claude-pal
git add lib/config.sh
git commit -m "feat(skills): opt-in 'pass' integration via PAL_CRED_SOURCE=pass:..."
```

### Task 7.4: Windows NTFS ACL check

**Files:**
- Modify: `~/repos/claude-pal/lib/config.sh`

- [ ] **Step 1: Implement NTFS ACL validation in pal_config_permissions_ok**

Replace the Windows branch in `pal_config_permissions_ok` with:

```bash
        MINGW*|MSYS*|CYGWIN*)
            # Validate NTFS ACL: only current user should have access
            local win_path
            win_path=$(cygpath -w "$path")
            local acl_output
            acl_output=$(icacls.exe "$win_path" 2>/dev/null || true)
            # Heuristic: expect lines for current user only, no "Everyone", "BUILTIN\Users" etc.
            if echo "$acl_output" | grep -qiE '(Everyone|BUILTIN\\Users|BUILTIN\\Authenticated Users)'; then
                echo "pal: config file $path has overly permissive ACL" >&2
                echo "pal: run: icacls \"$win_path\" /inheritance:r /grant:r \"%USERNAME%:F\"" >&2
                return 1
            fi
            ;;
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add lib/config.sh
git commit -m "feat(skills): validate NTFS ACL on config.env (Windows)"
```

**Milestone:** Skills run on all three OSes with platform-appropriate credential storage and permission checks.

---

## Phase 8: Documentation and release — **COMPLETE (v0.4.0)**

**Sequencing note (2026-04-19):** Phase 8 was executed before Phases 5 and 6 to validate the install/setup story. Live end-to-end dispatch passed (PR #27 on `Frightful-Games/recipe-manager-demo`). v0.4.0 tagged. A Phase 8-refresh pass after 5/6 will extend `docs/install.md` and CHANGELOG with the async/revise surface area.

**Feature set assumed built (pre-Phase 5/6):**
- Skills: `/claude-pal:pal-plan`, `/claude-pal:pal-implement` (sync only)
- Commands: `/claude-pal:pal-brainstorm` (depends on `superpowers` plugin), `/claude-pal:pal-setup`
- Container pipeline: adversarial review → TDD implement → post-impl review → PR
- Auth: env-passthrough only (no on-disk secrets file — see Task 4.6)

**Not yet built (do NOT reference in Phase 8 docs):**
- Async mode, `/pal-status`, `/pal-logs`, `/pal-cancel`, `/pal-revise` — land in Phases 5 and 6
- OS-native credential stores (macOS Keychain, Windows Credential Manager, Linux `pass`) — Phase 7 deferred


### Task 8.1: Install guide

**Files:**
- Create: `~/repos/claude-pal/docs/install.md`

Install guide must be written against the actually-built feature set (see Phase 8 heading). Env-passthrough auth only; no `config.env` file; no async/revise/status/logs/cancel skills. Those land in Phase 5/6 and a later Phase 8-refresh.

- [ ] **Step 1: Write `docs/install.md`**

```markdown
# Installing claude-pal

claude-pal is a Claude Code plugin that launches a Docker container to run the `claude` CLI non-interactively against GitHub issues. Everything runs on your host — no cloud service component.

## Prerequisites

- **Docker** 20+ (Docker Desktop on macOS/Windows; Docker Engine on Linux). `docker info` must succeed from your shell.
- **Claude Code CLI** installed on your host and logged in interactively at least once (`claude` in a terminal).
- **Git** and **`gh`** (GitHub CLI) installed.
- **Full-disk encryption** enabled on the host (LUKS / FileVault / BitLocker) — documented prerequisite, not enforced by claude-pal.
- **A Claude Pro / Max / Team / Enterprise subscription** (for OAuth) OR an **Anthropic Console API key**.

### Windows additional prerequisites

- **Git for Windows** (provides Git Bash, which Claude Code requires).
- If both WSL and Git Bash are installed, set `CLAUDE_CODE_GIT_BASH_PATH` in `~/.claude/settings.json`:
  ```json
  { "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe" } }
  ```

## Install steps

### 1. Clone the repo

```bash
git clone https://github.com/jnurre64/claude-pal.git ~/repos/claude-pal
cd ~/repos/claude-pal
```

### 2. Build the container image

```bash
./scripts/build-image.sh
# → builds claude-pal:latest on your local Docker daemon
```

Verify:

```bash
docker images claude-pal
```

### 3. Generate credentials

**Claude authentication** — pick exactly ONE of these:

- **Subscription OAuth** (common for personal use):
  ```bash
  claude setup-token
  # opens a browser, prints a token that begins sk-ant-oat01-
  # valid ~1 year
  ```
- **Console API key** (for commercial / multi-user / pay-as-you-go scenarios): create one at https://console.anthropic.com/settings/keys — begins `sk-ant-api03-`.

**GitHub token:** create a fine-grained PAT at https://github.com/settings/personal-access-tokens. Grant repository access for each repo you plan to dispatch against, with these scopes:

- Contents: read and write
- Pull requests: read and write
- Issues: read and write
- Metadata: read

### 4. Export credentials in your shell profile

claude-pal reads credentials from the process environment at dispatch time — there is no `config.env` file managed by the plugin. This matches Anthropic's documented [`claude-code-action`](https://github.com/anthropics/claude-code-action) pattern.

**Linux / macOS (bash):**
```bash
cat >> ~/.bashrc <<'EOF'

# claude-pal
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...paste-token-here...
export GH_TOKEN=github_pat_...paste-PAT-here...
EOF
source ~/.bashrc
```

Same for `~/.zshrc` (zsh). Use `set -x CLAUDE_CODE_OAUTH_TOKEN ...` syntax for fish in `~/.config/fish/config.fish`.

**Windows (PowerShell, persistent for the current user):**
```powershell
[System.Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'sk-ant-oat01-...', 'User')
[System.Environment]::SetEnvironmentVariable('GH_TOKEN', 'github_pat_...', 'User')
# Open a new PowerShell / Git Bash to pick up the new env
```

If you prefer an API key, substitute `CLAUDE_CODE_OAUTH_TOKEN` with `ANTHROPIC_API_KEY`. **Set exactly one of the two** — setting both is an error (preflight will reject it).

Alternative: once claude-pal is loaded as a plugin (step 5), run `/claude-pal:pal-setup` for a guided walkthrough.

### 5. Load claude-pal as a Claude Code plugin

claude-pal is a Claude Code plugin (manifest at `.claude-plugin/plugin.json`, shared libs at plugin-root `lib/`, skills under `skills/pal-*/SKILL.md`, commands under `commands/*.md`). It must be loaded *as a plugin* so `${CLAUDE_PLUGIN_ROOT}` is populated — do NOT copy `skills/pal-*` into `~/.claude/skills/`; the `lib/` sourcing inside each SKILL.md will fail.

**Developer / local-only (recommended today):**

```bash
# Validate the manifest (fast, no session needed)
claude plugin validate ~/repos/claude-pal
# → "✔ Validation passed"

# Load for one session at a time
claude --plugin-dir ~/repos/claude-pal
```

`--plugin-dir` is scoped to the one `claude` session. Inside that session, `/plugin` lists `claude-pal` and `/skills` lists `pal-implement` and `pal-plan`. Persistent / marketplace install is out of scope for v0.x.

### 6. Verify

Inside a `claude --plugin-dir ~/repos/claude-pal` session:

```
/plugin          # should show claude-pal as loaded
/skills          # should list pal-plan and pal-implement
```

From the host shell:

```bash
docker info                           # should succeed
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY" ] && echo "claude cred: ok"
[ -n "$GH_TOKEN" ] && echo "gh cred: ok"
GH_TOKEN="$GH_TOKEN" gh auth status   # should succeed
```

### 7. First live dispatch (validate end-to-end)

```
# Inside the claude --plugin-dir session, from a checkout of a GitHub repo the PAT can access:
/claude-pal:pal-plan
# → publishes the most recent docs/superpowers/plans/*.md file as a new issue
# → prints the issue URL

/claude-pal:pal-implement <the-issue-number>
# → runs preflight checks
# → launches the container (adversarial review → TDD → post-impl review → PR)
# → prints the PR URL on success
```

Watch for errors at each stage. Common failures are covered below.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `pal: missing required environment variable(s): ...` | Token not exported in current shell | Re-read step 4; open a new shell after editing your profile |
| `pal: ERROR — both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set` | Both auth env vars set | Unset whichever you don't want: `unset ANTHROPIC_API_KEY` (or vice-versa) |
| `docker daemon not reachable` | Docker not running / wrong `DOCKER_HOST` | Start Docker Desktop / `sudo systemctl start docker`; check `echo $DOCKER_HOST` |
| `Claude Code is using WSL's bash, not Git Bash` (Windows) | WSL precedence in Claude Code settings | Set `CLAUDE_CODE_GIT_BASH_PATH` in `~/.claude/settings.json` (see Prerequisites) |
| `gh auth status` fails | Expired PAT or missing scopes | Re-issue the PAT per step 3 |
| Container network failures | Firewall allowlist too narrow for a private registry | Add entries to `PAL_ALLOWLIST_EXTRA_DOMAINS` in the target repo's `.pal/config.env` |
| `/claude-pal:pal-brainstorm` stops with "install superpowers" | `superpowers` plugin not loaded in the session | `claude --plugin-dir ~/repos/claude-pal --plugin-dir <path-to-superpowers>` — or skip `pal-brainstorm` and use `/claude-pal:pal-plan` directly on a plan you already have |

## Terms of Service

Claude subscription OAuth tokens (`sk-ant-oat01-*`) are for personal use only per Anthropic's Consumer Terms of Service (Feb 2026 update). Do **not** redistribute your token, commit it to a repo, or deploy claude-pal as a shared service for others using someone else's subscription. For commercial or multi-user scenarios, use an `ANTHROPIC_API_KEY` from the Console instead.

See: https://www.anthropic.com/legal/usage-policy

## What's not in this release

v0.4.0 ships the core flow (plan → implement → PR) in sync mode. Planned for later releases:

- Async mode + `/claude-pal:pal-status`, `/claude-pal:pal-logs`, `/claude-pal:pal-cancel` (Phase 5)
- `/claude-pal:pal-revise` for PR-review follow-ups (Phase 6)
- OS-native credential stores — macOS Keychain, Windows Credential Manager, Linux `pass` (Phase 7 — deferred)
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add docs/install.md
git commit -m "docs: install guide for v0.4 (env-passthrough, sync-only)"
```

- [x] **Step 3: Credential prep for the live test**

Per user memory (`reference_github_finegrained_pat_collaborator.md`), the pennyworth-bot PAT is already exported in `~/.bashrc` — but under the name `GITHUB_TOKEN`, not `GH_TOKEN`. That var is load-bearing for the user's MCP github server, interactive `gh` for Frightful-Games repos, and the bot systemd service; do NOT rename or remove it. Add an alias line so claude-pal sees what it expects while everything else keeps working:

```bash
# Confirm with the user before editing their ~/.bashrc
echo '' >> ~/.bashrc
echo '# claude-pal reads GH_TOKEN; alias to the pennyworth-bot PAT that is already exported as GITHUB_TOKEN' >> ~/.bashrc
echo 'export GH_TOKEN="$GITHUB_TOKEN"' >> ~/.bashrc
source ~/.bashrc
```

`CLAUDE_CODE_OAUTH_TOKEN` is typically not in `~/.bashrc` yet. Ask the user whether to generate a fresh one with `claude setup-token` or use an existing token, then add it:

```bash
# Ask first: "Do you want to run claude setup-token now, or paste an existing token?"
# After they hand you a value:
echo 'export CLAUDE_CODE_OAUTH_TOKEN=<token>' >> ~/.bashrc
source ~/.bashrc
```

Verify (prints variable names only, values remain redacted):

```bash
env | grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN|GITHUB_TOKEN)=' | cut -d= -f1
# expected output, order may vary:
#   CLAUDE_CODE_OAUTH_TOKEN
#   GH_TOKEN
#   GITHUB_TOKEN
```

Also verify the PAT's repository access list includes `Frightful-Games/recipe-manager-demo`. If it was minted before that repo existed, it may need editing at https://github.com/settings/personal-access-tokens (→ Edit → Repository access):

```bash
GH_TOKEN="$GITHUB_TOKEN" gh issue list --repo Frightful-Games/recipe-manager-demo
# should list issues, not return 404
```

If that call 404s, stop and tell the user to add the repo to the PAT's access list before proceeding — do not attempt any guessing / retries.

- [x] **Step 4: Live validation** (the point of running Phase 8 now)

Open a fresh `claude --plugin-dir ~/repos/claude-pal` session (or `--plugin-dir ~/repos/claude-pal --plugin-dir <path-to-superpowers>` to include the `superpowers` plugin for `/claude-pal:pal-brainstorm`). Follow `docs/install.md` end-to-end against `Frightful-Games/recipe-manager-demo` using the credentials prepared in Step 3. Acceptance criteria:

1. Install guide steps 1–6 produce no ambiguity or missing info.
2. `/claude-pal:pal-plan` publishes a plan file as a GitHub issue comment on `Frightful-Games/recipe-manager-demo` (or creates a new issue if no issue number given).
3. `/claude-pal:pal-implement <#>` runs the container, goes through the gated pipeline, and opens a real PR on the repo.
4. Any rough edges get fixed in `docs/install.md` (and in the plugin's libs/commands if appropriate) and re-validated before marking Step 4 complete.

Do NOT mark Task 8.1 complete until the live round-trip produces a merged-ready PR URL on `Frightful-Games/recipe-manager-demo`.

### Task 8.2: Per-repo config example

Under the env-passthrough redesign (Task 4.6), there is no plugin-level `config.env` file — credentials are env vars in the user's shell profile. Only the per-repo non-secret config file remains, and an example of it belongs in the repo.

**Files:**
- Create: `~/repos/claude-pal/.pal/config.env.example`

- [x] **Step 1: Write `.pal/config.env.example`**

```bash
mkdir -p ~/repos/claude-pal/.pal
cat > ~/repos/claude-pal/.pal/config.env.example <<'EOF'
# Per-repo claude-pal config — non-secret only.
# Copy to <your-project>/.pal/config.env and commit to your project repo.
# Credentials (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, GH_TOKEN) live in
# your shell profile, NOT here — see docs/install.md in the claude-pal repo.

# Test commands
# AGENT_TEST_COMMAND=bun test
# AGENT_TEST_SETUP_COMMAND=bun install

# Phase-specific tool allowlists
# AGENT_ALLOWED_TOOLS_IMPLEMENT=Read,Write,Edit,Bash(bun *),Bash(git *)

# Model overrides
# AGENT_MODEL_IMPLEMENT=claude-sonnet-4-6
# AGENT_MODEL_ADVERSARIAL_PLAN=claude-sonnet-4-6

# Review gate toggles
# AGENT_ADVERSARIAL_PLAN_REVIEW=true
# AGENT_POST_IMPL_REVIEW=true
# AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1

# Allowlist extensions for private registries
# PAL_ALLOWLIST_EXTRA_DOMAINS=private.registry.example.com,artifactory.internal

# Remote Docker daemon
# DOCKER_HOST=ssh://user@windows-box
EOF
```

- [x] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add .pal/config.env.example
git commit -m "docs: add per-repo .pal/config.env example (non-secret)"
```

### Task 8.3: Upstream drift check script

**Files:**
- Create: `~/repos/claude-pal/scripts/diff-upstream.sh`

- [x] **Step 1: Write diff-upstream.sh**

```bash
cat > ~/repos/claude-pal/scripts/diff-upstream.sh <<'EOF'
#!/bin/bash
# Diff vendored files against a local claude-agent-dispatch checkout to find upstream drift.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-$HOME/claude-agent-dispatch}"
if [ ! -d "$UPSTREAM_REPO" ]; then
    echo "diff-upstream: $UPSTREAM_REPO not found (set UPSTREAM_REPO to a local clone)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

declare -A MAP=(
    ["image/opt/pal/prompts/adversarial-plan.md"]="prompts/adversarial-plan.md"
    ["image/opt/pal/prompts/post-impl-review.md"]="prompts/post-impl-review.md"
    ["image/opt/pal/prompts/post-impl-retry.md"]="prompts/post-impl-retry.md"
    ["image/opt/pal/prompts/implement.md"]="prompts/implement.md"
    ["image/opt/pal/lib/review-gates.sh"]="scripts/lib/review-gates.sh"
)

echo "=== Upstream commit ==="
(cd "$UPSTREAM_REPO" && git log --oneline -1)
echo ""

exit_code=0
for local_file in "${!MAP[@]}"; do
    upstream_file="${MAP[$local_file]}"
    printf -- "--- %s ---\n" "$local_file"
    if diff -u "$UPSTREAM_REPO/$upstream_file" "$REPO_ROOT/$local_file" > /tmp/pal-diff.txt; then
        echo "(unchanged)"
    else
        cat /tmp/pal-diff.txt
        exit_code=1
    fi
    echo ""
done

exit $exit_code
EOF
chmod +x ~/repos/claude-pal/scripts/diff-upstream.sh
```

- [x] **Step 2: Commit**

```bash
cd ~/repos/claude-pal
git add scripts/diff-upstream.sh
git commit -m "scripts: diff-upstream.sh for tracking vendored file drift"
```

### Task 8.4: README cross-check

The README was already expanded in Task 4.6 with the auth section, ToS note, plugin entry points, and a pointer to `docs/superpowers/specs/...` for design. This task verifies `README.md` and `docs/install.md` agree (no drift) and adds two missing sections identified during the Phase 8 write-up.

**Files:**
- Modify: `~/repos/claude-pal/README.md`

- [x] **Step 1: Diff README vs install guide, fix any drift**

Compare the auth section in `README.md` to the "Export credentials in your shell profile" section in `docs/install.md`. They must agree on: env var names, shell profile file conventions, OAuth-vs-API-key wording, ToS note. If they disagree, update README to match the install guide.

- [x] **Step 2: Add "What it does" and "Getting started" sections to README**

Append (above the existing "Authentication" section):

```markdown
## What it does

1. You brainstorm and write an implementation plan (ideally via `superpowers:brainstorming` + `superpowers:writing-plans`).
2. You run `/claude-pal:pal-plan` to post that plan to a GitHub issue with an `<!-- agent-plan -->` marker.
3. You run `/claude-pal:pal-implement <issue#>` to launch an ephemeral Docker container that:
   - Runs an **adversarial plan review** (fresh Claude session, read-only, verifies the plan matches the issue)
   - Implements the plan using **TDD with a retry loop** that feeds failing tests back to the model
   - Runs a **post-implementation review** (fresh session, read-only, checks the diff for scope creep / test quality)
   - Retries once if the post-review finds concerns
   - Pushes the branch and opens a PR

Runs are ephemeral. Credentials never enter the image — only the running container's env for the duration of one run.

## Getting started

See [`docs/install.md`](docs/install.md).

## Relationship to `claude-pal-action`

Sibling project. `claude-pal-action` (formerly `claude-agent-dispatch`) runs the same pipeline shape on self-hosted GitHub Actions runners for team / shared use. claude-pal is personal, local, and triggered from a Claude Code session rather than GitHub labels. claude-pal vendors the review-gate prompts and orchestration library from upstream — see `UPSTREAM.md`.
```

- [x] **Step 3: Commit**

```bash
cd ~/repos/claude-pal
git add README.md
git commit -m "docs(readme): add 'What it does' and 'Getting started' sections"
```

### Task 8.5: CHANGELOG and v0.4.0 tag

Ships the partial release milestone: core flow (plan → sync implement → PR) with install guide and live-validated end-to-end. v1.0.0 lands after Phases 5 + 6 + Phase 8-refresh.

**Files:**
- Create: `~/repos/claude-pal/CHANGELOG.md`
- Update: `~/repos/claude-pal/.claude-plugin/plugin.json` — bump `version` from `0.1.0` to `0.4.0`

- [x] **Step 1: Write CHANGELOG**

```markdown
# Changelog

## [0.4.0] — 2026-04-XX

First dogfood-ready release. Ships the core flow from an ideation session to an opened PR.

### Added
- **Plugin packaging** — `.claude-plugin/plugin.json`, shared libs at plugin-root `lib/`, skills under `skills/`, commands under `commands/`. Loads via `claude --plugin-dir`.
- **Skills:** `/claude-pal:pal-plan`, `/claude-pal:pal-implement` (sync mode)
- **Commands:** `/claude-pal:pal-brainstorm` (orchestrator for the full flow; depends on the `superpowers` plugin), `/claude-pal:pal-setup` (guided credential walkthrough)
- **Container pipeline:** adversarial plan review → TDD implement with retry loop → post-impl review → retry once on concerns → push branch + open PR
- **Auth: env-passthrough only** — reads `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`) + `GH_TOKEN` from the process env, forwards to container at `docker run -e`. No on-disk secrets file. Matches Anthropic's `claude-code-action` pattern.
- **Preflight checks** — auth present, single auth method, Docker reachable, Windows bash, `gh auth status`, no-double-dispatch lock
- **Per-repo config** — `.pal/config.env` for non-secret project knobs (test commands, model overrides, allowlist extensions)
- **Vendored review-gate library** — prompts + `review-gates.sh` from `jnurre64/claude-pal-action` (formerly `claude-agent-dispatch`); see `UPSTREAM.md`

### Documentation
- `docs/install.md` — install guide
- `README.md` — project overview + auth + ToS
- `docs/superpowers/specs/2026-04-18-claude-pal-design.md` — full design
- `docs/superpowers/plans/2026-04-18-claude-pal.md` — implementation plan
- `UPSTREAM.md` — vendored-file tracking

### Not in 0.4.0 (planned for 0.5 / 0.6)
- Async mode, `/pal-status`, `/pal-logs`, `/pal-cancel` (Phase 5)
- `/pal-revise` for PR-review follow-ups (Phase 6)
- OS-native credential stores — macOS Keychain, Windows Credential Manager, Linux `pass` (Phase 7, deferred)
```

- [x] **Step 2: Bump plugin version**

Update `.claude-plugin/plugin.json` `version` field from `"0.1.0"` to `"0.4.0"`. Revalidate the manifest: `claude plugin validate ~/repos/claude-pal`.

- [x] **Step 3: Tag v0.4.0**

```bash
cd ~/repos/claude-pal
git add CHANGELOG.md .claude-plugin/plugin.json
git commit -m "chore: CHANGELOG and bump version to 0.4.0"
git tag -a v0.4.0 -m "v0.4.0 — core flow: plan → sync implement → PR"
```

Do NOT push the tag unless you have a published remote; local-only is fine for this release.

**Milestone (v0.4.0):** Install guide is accurate, live round-trip on `Frightful-Games/recipe-manager-demo` produced a PR, CHANGELOG published, version tagged. Phases 5 + 6 can now layer on a validated foundation.

---

## Self-review checklist

1. **Spec coverage.** Every v1 requirement from the spec has a corresponding task:
   - Skills × 6 — Tasks 3.5, 4.3, 5.4, 5.5, 5.6, 6.1
   - Config + preflight — Tasks 3.1, 3.2, 7.1–7.4
   - Run registry — Tasks 3.3, 5.4
   - Container pipeline (phases 1–11 from spec §6.2) — Tasks 2.1–2.9
   - Firewall allowlist — Task 2.2
   - Vendored review gates — Tasks 1.3, 1.4, 1.5, 2.6, 2.8
   - Plan publishing marker — Task 4.2
   - Sync/async — Tasks 3.4, 5.2, 5.3
   - Cross-platform notifier — Task 5.1
   - Status/logs/cancel — Tasks 5.4, 5.5, 5.6
   - Windows Git Bash preflight — Task 3.2 (built-in) + 7.4 (NTFS ACL)
   - UPSTREAM tracking + diff script — Tasks 1.5, 8.3
   - Docs + examples + release — Tasks 8.1, 8.2, 8.4, 8.5
2. **Placeholders:** no "TBD/TODO/implement later" in any step. Every code block contains concrete code or a concrete command.
3. **Type consistency:** status.json schema fields, env var names, and function names (`pal_load_config`, `pal_preflight_all`, `pal_launch_sync`, `pal_launch_async`, `pal_new_run_id`, `pal_run_dir`, `pal_acquire_lock`, `pal_release_lock`) are used consistently across phases.
4. **Ambiguity:** none flagged. Preflight behavior, status outcomes, phase names, and retry counts all defined explicitly.

Plan complete. Ready for execution.
