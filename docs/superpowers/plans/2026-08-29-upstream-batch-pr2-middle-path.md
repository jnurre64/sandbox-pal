# Upstream Batch PR 2 — Container Middle Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the "middle path" from the #30 decision: host memory reaches the container as a read-only directory (index injected, files readable), selected host skills sync in by name, memory proposals harvested by PR 1 get a `/pal-memory` triage skill, and the decision is recorded on #30 and in the design doc.

**Architecture:** All changes are host-side bash under plugin-root `lib/` (sourced via `${CLAUDE_PLUGIN_ROOT}/lib/...`) plus one new skill/command pair. The container runner (`image/opt/pal/lib/claude-runner.sh`, PR 1) already consumes `AGENT_MEMORY_DIR` — this PR makes the launcher produce it. Tests run against the existing `tests/test_helper/fake-docker.sh` shim: they assert on the recorded `docker` argv, never on a real container.

**Tech Stack:** bash (`set -euo pipefail`), jq, BATS-Core (`tests/bats/bin/bats`, `bats-support`, `bats-assert`), shellcheck.

**Spec:** `docs/superpowers/specs/2026-08-29-upstream-batch-adoption-design.md` §2.1, §2.3, §3.6, §4 (PR 2 rows), §5. Issue: https://github.com/jnurre64/sandbox-pal/issues/31 (PR 2 row); decision target: https://github.com/jnurre64/sandbox-pal/issues/30.

## Global Constraints

- All shell scripts pass `shellcheck` with zero warnings at CI's level (`shellcheck -S info` locally — CI's shellcheck is older and treats SC2015-class info findings as failures); all scripts use `set -euo pipefail`; library files are `set -u`-safe (`${VAR:-}` for every optional var).
- Full check before every commit, from repo root: `shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/`.
- `SKILL.md` files reference helpers only as `. "${CLAUDE_PLUGIN_ROOT}/lib/foo.sh"` — never `claude-skill-path` or `$(dirname "${BASH_SOURCE[0]}")`.
- Tests first, watched failing. No secrets in any file; the test token is `github_pat_fake` (matches `tests/test_skill_pal_workspace.bats`).
- Memory is **never** written on the host automatically; only `/pal-memory --adopt` writes under `~/.claude/projects/`.
- Commit prefixes: `feat(host):`, `fix(host):`, `test(host):`, `docs:`. Every commit ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BkWFyA2AvNHr4a77gM9yUN`.
- Branch: `feature/31-middle-path` off `main` (after PR #32 merged). PR title: `feat(host): container middle path — read-only memory, skills sync, /pal-memory (#30 decision)`; body `Part 2 of 3 for #31` — do **not** write `Closes #31` or `Closes #30`.

---

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `lib/memory-sync.sh` | modify | Copy host memory to `/home/agent/memory/<host-slug>` read-only; export `AGENT_MEMORY_DIR` |
| `lib/launcher.sh` | modify | Forward `AGENT_MEMORY_DIR`; call skills sync next to rules sync in both launchers |
| `lib/config.sh` | modify | `PAL_SYNC_SKILLS` knob (default empty), documented in header |
| `lib/skills-sync.sh` | create | `pal_skills_sync_to_container` |
| `lib/memory-proposals.sh` | create | `pal_memory_proposals_list`, `pal_memory_proposal_adopt`, `pal_memory_proposal_discard` |
| `skills/pal-memory/SKILL.md`, `commands/pal-memory.md` | create | `/pal-memory [run-id] [--adopt <file>] [--discard <file>]` |
| `tests/test_memory_sync.bats` | modify | New destination, root-owned/read-only exec calls, `AGENT_MEMORY_DIR` |
| `tests/test_launcher.bats` | modify | `AGENT_MEMORY_DIR` forwarded; skills sync invoked |
| `tests/test_skills_sync.bats`, `tests/test_memory_proposals.bats`, `tests/test_skill_pal_memory.bats` | create | Unit + skill smoke tests |
| `docs/superpowers/specs/2026-04-18-sandbox-pal-design.md` | modify | §9.5 decision; §5.3 flag surface example |
| `CHANGELOG.md` | modify | Unreleased: Added / Changed |

---

### Task 1: Read-only memory directory and `AGENT_MEMORY_DIR`

**Files:**
- Modify: `lib/memory-sync.sh` (function `pal_memory_sync_to_container`, lines 25–61)
- Modify: `lib/launcher.sh:16-35` (`_pal_launcher_env_args`)
- Test: `tests/test_memory_sync.bats`, `tests/test_launcher.bats`

**Interfaces:**
- Produces: `pal_memory_sync_to_container <host-repo-path> <container-workdir>` (signature unchanged; second arg now unused but kept so `pal-implement`/`pal-revise` SKILL.md call sites do not change) — on a successful sync it sets and exports `AGENT_MEMORY_DIR=/home/agent/memory/<host-slug>`; when skipped (knob off or no host dir) it leaves `AGENT_MEMORY_DIR` untouched. `_pal_launcher_env_args` emits `-e AGENT_MEMORY_DIR=…` when the variable is non-empty.
- Consumes (container side, PR 1): `claude-runner.sh: _resolve_memory_dir / load_shared_memory` read `AGENT_MEMORY_DIR`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_memory_sync.bats`, replace the test `pal_memory_sync_to_container copies MEMORY.md and topic .md files` with:

```bash
@test "pal_memory_sync_to_container copies to a root-owned read-only dir under /home/agent/memory and exports AGENT_MEMORY_DIR" {
    fake_docker_set_running

    local host_proj="$BATS_TEST_TMPDIR/host/.claude/projects/-home-me-repos-foo/memory"
    mkdir -p "$host_proj"
    echo "# index" > "$host_proj/MEMORY.md"
    echo "# topic" > "$host_proj/user_role.md"
    echo '{"secret":1}' > "$host_proj/session.jsonl"

    export HOME="$BATS_TEST_TMPDIR/host" PAL_SYNC_MEMORIES=true
    unset AGENT_MEMORY_DIR
    pal_memory_sync_to_container /home/me/repos/foo /home/agent/work/run-1
    assert_equal "$AGENT_MEMORY_DIR" "/home/agent/memory/-home-me-repos-foo"
    run bash -c 'printenv AGENT_MEMORY_DIR'
    assert_output "/home/agent/memory/-home-me-repos-foo"

    # Previous copy is root-owned, so removal and creation happen as root.
    run grep -E '^exec -u root sandbox-pal-workspace rm -rf /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E '^exec -u root sandbox-pal-workspace mkdir -p /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E '^cp .* sandbox-pal-workspace:/home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    # Read-only for the unprivileged agent user: root-owned, go=rX.
    run grep -E '^exec -u root sandbox-pal-workspace chown -R root:root /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E '^exec -u root sandbox-pal-workspace chmod -R u=rwX,go=rX /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    # The old writable project-slug destination must not be used any more.
    run grep -E '/home/agent/.claude/projects/' "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "REGRESSION: *.jsonl never reaches the docker cp payload unless PAL_SYNC_TRANSCRIPTS=true" {
    fake_docker_set_running
    local host_proj="$BATS_TEST_TMPDIR/host/.claude/projects/-home-me-repos-foo/memory"
    mkdir -p "$host_proj"
    echo "# index" > "$host_proj/MEMORY.md"
    echo '{"secret":1}' > "$host_proj/session.jsonl"
    # Capture the staging dir the lib hands to docker cp by making the shim
    # snapshot it: the fake docker only logs argv, so list the source instead.
    export HOME="$BATS_TEST_TMPDIR/host" PAL_SYNC_MEMORIES=true
    cat > "$FAKE_DOCKER_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = cp ]; then find "${2%/.}" -type f -printf '%f\n' >> "$FAKE_DOCKER_LOG"; fi
if [ "$1" = ps ]; then echo sandbox-pal-workspace; fi
exit 0
SHIM
    pal_memory_sync_to_container /home/me/repos/foo /home/agent/work/run-1
    run grep -c 'session.jsonl' "$FAKE_DOCKER_LOG"; assert_output "0"
    run grep -c '^MEMORY.md$' "$FAKE_DOCKER_LOG"; assert_output "1"
}
```

Also change the no-op tests so they prove `AGENT_MEMORY_DIR` stays unset:

```bash
@test "pal_memory_sync_to_container is a no-op when PAL_SYNC_MEMORIES=false" {
    fake_docker_set_running
    unset AGENT_MEMORY_DIR
    PAL_SYNC_MEMORIES=false pal_memory_sync_to_container /any /any
    run grep "^cp " "$FAKE_DOCKER_LOG"
    assert_failure
    [ -z "${AGENT_MEMORY_DIR:-}" ]
}

@test "pal_memory_sync_to_container does nothing if host memory dir absent" {
    fake_docker_set_running
    unset AGENT_MEMORY_DIR
    HOME="$BATS_TEST_TMPDIR/empty" pal_memory_sync_to_container /nope /home/agent/work/run-1
    run grep "^cp " "$FAKE_DOCKER_LOG"
    assert_failure
    [ -z "${AGENT_MEMORY_DIR:-}" ]
}
```

Note: `FAKE_DOCKER_DIR` is set by `fake_docker_setup` but not exported — add `export FAKE_DOCKER_DIR` to the `export FAKE_DOCKER_LOG FAKE_DOCKER_STATE` line in `tests/test_helper/fake-docker.sh` (one-word change; it is a plain variable in the same shell either way, the export just makes the intent explicit).

Append to `tests/test_launcher.bats`:

```bash
@test "_pal_launcher_env_args forwards AGENT_MEMORY_DIR when set and omits it otherwise" {
    unset AGENT_MEMORY_DIR
    local -a args=()
    GH_TOKEN=ghp_x _pal_launcher_env_args run-1 args
    run printf '%s\n' "${args[@]}"
    refute_line --partial "AGENT_MEMORY_DIR"

    export AGENT_MEMORY_DIR=/home/agent/memory/-home-me-repos-foo
    args=()
    GH_TOKEN=ghp_x _pal_launcher_env_args run-1 args
    run printf '%s\n' "${args[@]}"
    assert_line "AGENT_MEMORY_DIR=/home/agent/memory/-home-me-repos-foo"
}

@test "pal_launch_sync passes the synced memory dir to docker exec" {
    fake_docker_set_running
    mkdir -p "$HOME/.claude/projects/-home-me-repos-foo/memory"
    echo "# idx" > "$HOME/.claude/projects/-home-me-repos-foo/memory/MEMORY.md"
    unset AGENT_MEMORY_DIR
    GH_TOKEN=ghp_x run pal_launch_sync implement owner/repo 42 /home/me/repos/foo run-test-2
    assert_success
    run grep -- "^exec .*-e AGENT_MEMORY_DIR=/home/agent/memory/-home-me-repos-foo .*run-pipeline.sh" "$FAKE_DOCKER_LOG"
    assert_success
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tests/bats/bin/bats tests/test_memory_sync.bats tests/test_launcher.bats`
Expected: the new memory-sync test fails on `assert_equal` (`AGENT_MEMORY_DIR` empty) and the `/home/agent/.claude/projects/` grep; the launcher tests fail on the `AGENT_MEMORY_DIR` line assertions.

- [ ] **Step 3: Implement**

Replace `pal_memory_sync_to_container` in `lib/memory-sync.sh` (keep `pal_memory_slug`) with:

```bash
# pal_memory_sync_to_container <host-repo-path> <container-workdir>
#
# One-way sync of Claude Code Auto Memory markdown from the host into the
# workspace container at /home/agent/memory/<host-slug>/ — a directory the
# container's claude does NOT auto-load or write. The runner injects its
# MEMORY.md via --append-system-prompt and exposes the files with --add-dir
# (see image/opt/pal/lib/claude-runner.sh: load_shared_memory). The copy is
# root-owned and go=rX so the unprivileged agent user cannot modify it or
# chmod it back; phases propose changes via .agent-data/memory-proposals/.
#
# On success exports AGENT_MEMORY_DIR (read by _pal_launcher_env_args).
# <container-workdir> is accepted for call-site compatibility and unused.
#
# *.jsonl transcripts are excluded by default (secret-tier). Set
# PAL_SYNC_TRANSCRIPTS=true to include them (not recommended).
pal_memory_sync_to_container() {
    local host_repo="$1"
    # shellcheck disable=SC2034  # kept for call-site compatibility
    local container_workdir="${2:-}"

    [ "${PAL_SYNC_MEMORIES:-true}" = "true" ] || return 0

    local host_slug host_dir container_dir
    host_slug="$(pal_memory_slug "$host_repo")"
    host_dir="${HOME}/.claude/projects/${host_slug}/memory"
    container_dir="/home/agent/memory/${host_slug}"

    [ -d "$host_dir" ] || return 0

    # The previous run's copy is root-owned: remove and recreate as root.
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        rm -rf "$container_dir" >/dev/null 2>&1 || true
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        mkdir -p "$container_dir" >/dev/null

    # Stage a filtered copy so the docker cp payload never contains *.jsonl
    # unless the user opted in.
    local staging
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    if [ "${PAL_SYNC_TRANSCRIPTS:-false}" = "true" ]; then
        cp -r "$host_dir/." "$staging/"
    else
        (
            cd "$host_dir" || exit 0
            find . -type f \! -name '*.jsonl' -print0 \
                | xargs -0 -I{} cp --parents {} "$staging/"
        )
    fi

    docker cp "$staging/." "${PAL_WORKSPACE_NAME}:${container_dir}"

    # Read-only to the agent user (docker cp lands files as root already;
    # make it explicit and strip any group/other write bits from the host).
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        chown -R root:root "$container_dir" >/dev/null
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        chmod -R u=rwX,go=rX "$container_dir" >/dev/null

    AGENT_MEMORY_DIR="$container_dir"
    export AGENT_MEMORY_DIR
}
```

In `lib/launcher.sh` `_pal_launcher_env_args`, after the `PAL_ALLOWLIST_EXTRA_DOMAINS` line add:

```bash
    [ -n "${AGENT_MEMORY_DIR:-}" ]            && _out+=(-e "AGENT_MEMORY_DIR=${AGENT_MEMORY_DIR}")
```

and update the function's header comment to mention `AGENT_MEMORY_DIR` ("set by pal_memory_sync_to_container").

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck -S info lib/memory-sync.sh lib/launcher.sh tests/test_helper/fake-docker.sh && ./tests/bats/bin/bats tests/test_memory_sync.bats tests/test_launcher.bats`
Expected: all green. If `pal_launch_sync` test fails on the `-e AGENT_MEMORY_DIR` grep, check that `_pal_launcher_env_args` runs **after** `pal_memory_sync_to_container` in `pal_launch_sync` (it does: sync happens first, env args are built later).

- [ ] **Step 5: Commit**

```bash
git add lib/memory-sync.sh lib/launcher.sh tests/test_memory_sync.bats tests/test_launcher.bats tests/test_helper/fake-docker.sh
git commit -m "feat(host): sync memory into a root-owned read-only dir and pass AGENT_MEMORY_DIR to the pipeline"
```

---

### Task 2: Skills sync by name (`PAL_SYNC_SKILLS`)

**Files:**
- Create: `lib/skills-sync.sh`
- Modify: `lib/config.sh` (header comment + defaults block), `lib/launcher.sh` (`pal_launch_sync`, `pal_launch_async`)
- Test: `tests/test_skills_sync.bats` (create), `tests/test_launcher.bats`

**Interfaces:**
- Produces: `pal_skills_sync_to_container` — reads `PAL_SYNC_SKILLS` (comma-separated skill directory names under `~/.claude/skills/`); for each: `docker exec rm -rf /home/agent/.claude/skills/<name>`, stage `cp -rL`, `docker cp` to `/home/agent/.claude/skills/<name>`; prints `pal: skill '<name>' not found under ~/.claude/skills — skipped` to stderr for missing names; returns 0 always. Empty/unset `PAL_SYNC_SKILLS` → no docker calls.
- `pal_load_config` sets `: "${PAL_SYNC_SKILLS:=}"` and exports it.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_skills_sync.bats`:

```bash
#!/usr/bin/env bats
# shellcheck shell=bash
# lib/skills-sync.sh: opt-in, by-name sync of ~/.claude/skills/<name> into the
# workspace container. Default (PAL_SYNC_SKILLS empty) syncs nothing.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/skills/alpha" "$HOME/.claude/skills/beta"
    echo "# alpha" > "$HOME/.claude/skills/alpha/SKILL.md"
    echo "# beta"  > "$HOME/.claude/skills/beta/SKILL.md"
    fake_docker_setup
    fake_docker_set_running
    # shellcheck source=../lib/skills-sync.sh
    . "$REPO_ROOT/lib/skills-sync.sh"
}

teardown() { fake_docker_teardown; }

@test "default (PAL_SYNC_SKILLS empty) syncs nothing" {
    unset PAL_SYNC_SKILLS
    run pal_skills_sync_to_container
    assert_success
    run grep -c . "$FAKE_DOCKER_LOG"; assert_output "0"
    PAL_SYNC_SKILLS="" run pal_skills_sync_to_container
    assert_success
    run grep -c . "$FAKE_DOCKER_LOG"; assert_output "0"
}

@test "named skills are removed in the container then copied in, one docker cp per skill" {
    PAL_SYNC_SKILLS="alpha, beta" run pal_skills_sync_to_container
    assert_success
    run grep -E '^exec sandbox-pal-workspace rm -rf /home/agent/.claude/skills/alpha$' "$FAKE_DOCKER_LOG"; assert_success
    run grep -E '^exec sandbox-pal-workspace rm -rf /home/agent/.claude/skills/beta$'  "$FAKE_DOCKER_LOG"; assert_success
    run grep -E '^exec sandbox-pal-workspace mkdir -p /home/agent/.claude/skills$' "$FAKE_DOCKER_LOG"; assert_success
    run grep -cE '^cp .* sandbox-pal-workspace:/home/agent/.claude/skills/(alpha|beta)$' "$FAKE_DOCKER_LOG"; assert_output "2"
}

@test "a symlinked skill directory is dereferenced before copy" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere/gamma"
    echo "# gamma" > "$BATS_TEST_TMPDIR/elsewhere/gamma/SKILL.md"
    ln -s "$BATS_TEST_TMPDIR/elsewhere/gamma" "$HOME/.claude/skills/gamma"
    # Make the shim record the staged source's SKILL.md content.
    cat > "$FAKE_DOCKER_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = cp ]; then
    src="${2%/.}"
    [ -L "$src" ] && echo "SYMLINK" >> "$FAKE_DOCKER_LOG"
    cat "$src/SKILL.md" >> "$FAKE_DOCKER_LOG"
fi
[ "$1" = ps ] && echo sandbox-pal-workspace
exit 0
SHIM
    PAL_SYNC_SKILLS=gamma run pal_skills_sync_to_container
    assert_success
    run grep -c '^SYMLINK$' "$FAKE_DOCKER_LOG"; assert_output "0"
    run grep -c '^# gamma$' "$FAKE_DOCKER_LOG"; assert_output "1"
}

@test "a missing skill name warns on stderr, is skipped, and does not fail the sync" {
    PAL_SYNC_SKILLS="alpha,nope" run pal_skills_sync_to_container
    assert_success
    assert_output --partial "pal: skill 'nope' not found under"
    run grep -c 'skills/nope' "$FAKE_DOCKER_LOG"; assert_output "0"
    run grep -cE '^cp .*skills/alpha$' "$FAKE_DOCKER_LOG"; assert_output "1"
}
```

Append to `tests/test_launcher.bats`:

```bash
@test "pal_launch_sync and pal_launch_async sync PAL_SYNC_SKILLS before exec" {
    fake_docker_set_running
    mkdir -p "$HOME/.claude/skills/alpha"; echo "# a" > "$HOME/.claude/skills/alpha/SKILL.md"
    export PAL_SYNC_SKILLS=alpha
    GH_TOKEN=ghp_x run pal_launch_sync implement owner/repo 42 /home/me/repos/foo run-test-3
    assert_success
    run grep -cE '^cp .*sandbox-pal-workspace:/home/agent/.claude/skills/alpha$' "$FAKE_DOCKER_LOG"; assert_output "1"
    : > "$FAKE_DOCKER_LOG"
    GH_TOKEN=ghp_x run pal_launch_async implement owner/repo 42 /home/me/repos/foo run-test-4
    assert_success
    run grep -cE '^cp .*sandbox-pal-workspace:/home/agent/.claude/skills/alpha$' "$FAKE_DOCKER_LOG"; assert_output "1"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tests/bats/bin/bats tests/test_skills_sync.bats tests/test_launcher.bats`
Expected: `test_skills_sync.bats` fails in `setup` (`lib/skills-sync.sh: No such file`); the launcher test fails on the `cp` count (`0`).

- [ ] **Step 3: Implement**

Create `lib/skills-sync.sh`:

```bash
# lib/skills-sync.sh
# shellcheck shell=bash
# Opt-in, by-name sync of host Claude Code skills into the workspace
# container. Nothing inherits silently: PAL_SYNC_SKILLS (comma-separated
# directory names under ~/.claude/skills/) is empty by default.

# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"

# pal_skills_sync_to_container
#
# For each name in PAL_SYNC_SKILLS: remove the container copy (so host
# deletions propagate), stage a dereferenced copy (host skills are often
# symlinks into per-skill repos), docker cp it to
# /home/agent/.claude/skills/<name>. Missing names warn and are skipped.
pal_skills_sync_to_container() {
    local names="${PAL_SYNC_SKILLS:-}"
    [ -n "$names" ] || return 0

    local host_skills="${HOME}/.claude/skills"
    local container_skills="/home/agent/.claude/skills"

    local staging
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    docker exec "$PAL_WORKSPACE_NAME" mkdir -p "$container_skills" >/dev/null

    local name
    IFS=',' read -ra _names <<< "$names"
    for name in "${_names[@]}"; do
        name="${name#"${name%%[![:space:]]*}"}"   # ltrim
        name="${name%"${name##*[![:space:]]}"}"   # rtrim
        [ -n "$name" ] || continue
        if [ ! -d "$host_skills/$name" ]; then
            echo "pal: skill '$name' not found under ~/.claude/skills — skipped" >&2
            continue
        fi
        rm -rf "${staging:?}/$name"
        cp -rL "$host_skills/$name" "$staging/$name"
        docker exec "$PAL_WORKSPACE_NAME" rm -rf "$container_skills/$name" >/dev/null 2>&1 || true
        docker cp "$staging/$name" "${PAL_WORKSPACE_NAME}:${container_skills}/${name}"
    done
    return 0
}
```

In `lib/config.sh`: add `#   PAL_SYNC_SKILLS       (default empty — comma-separated ~/.claude/skills names to sync)` to the header list, and in `pal_load_config` after `: "${PAL_SYNC_TRANSCRIPTS:=false}"` add `: "${PAL_SYNC_SKILLS:=}"` and change the export line to `export PAL_SYNC_MEMORIES PAL_SYNC_TRANSCRIPTS PAL_SYNC_SKILLS`.

In `lib/launcher.sh`, in **both** `pal_launch_sync` and `pal_launch_async`: after the `. "${CLAUDE_PLUGIN_ROOT}/lib/container-rules.sh"` source line add

```bash
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/skills-sync.sh"
```

and after `pal_container_rules_sync_to_container` add `pal_skills_sync_to_container`. Update the file header comment: "Memory, container-CLAUDE.md and opt-in skills are synced before exec."

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck -S info lib/skills-sync.sh lib/config.sh lib/launcher.sh && ./tests/bats/bin/bats tests/test_skills_sync.bats tests/test_launcher.bats tests/test_config.bats`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/skills-sync.sh lib/config.sh lib/launcher.sh tests/test_skills_sync.bats tests/test_launcher.bats
git commit -m "feat(host): opt-in skills sync into the workspace (PAL_SYNC_SKILLS)"
```

---

### Task 3: Memory-proposal triage library

**Files:**
- Create: `lib/memory-proposals.sh`
- Test: `tests/test_memory_proposals.bats` (create)

**Interfaces:**
- Consumes: `pal_runs_dir`, `pal_run_dir` (`lib/runs.sh`), `pal_memory_slug` (`lib/memory-sync.sh`).
- Produces:
  - `pal_memory_proposals_list [run-id]` → one line per pending proposal: `<run-id>\t<file>\t<name> — <description>`; with no run-id, scans every run dir under `pal_runs_dir` that has `memory-proposals/*.md`; prints `pal: no pending memory proposals` to stderr and returns 0 when none.
  - `pal_memory_proposal_adopt <run-id> <file> <host-repo-path>` → copies `<run-dir>/memory-proposals/<file>` to `~/.claude/projects/<slug>/memory/<file>`, appends `- [<name>](<file>) — <description>` to that dir's `MEMORY.md` (creating it with `# Memory Index` when absent), moves the proposal to `memory-proposals/.triaged/`. Returns 1 (no writes) when: the file is missing; frontmatter lacks `name:`; `name` ≠ filename without `.md`; a memory file with that filename already exists (prints `diff -u` of existing vs proposal).
  - `pal_memory_proposal_discard <run-id> <file>` → moves the proposal to `.triaged/`; returns 1 if missing.
  - `_pal_proposal_field <file> <key>` → frontmatter scalar value.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_memory_proposals.bats`:

```bash
#!/usr/bin/env bats
# shellcheck shell=bash
# lib/memory-proposals.sh: list / adopt / discard proposals harvested to
# <runs>/<run-id>/memory-proposals/ by run-pipeline.sh (PR 1).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$HOME"
    # shellcheck source=../lib/runs.sh
    . "$REPO_ROOT/lib/runs.sh"
    # shellcheck source=../lib/memory-proposals.sh
    . "$REPO_ROOT/lib/memory-proposals.sh"
    RUN1="$(pal_run_dir run-1)"; RUN2="$(pal_run_dir run-2)"
    mkdir -p "$RUN1/memory-proposals" "$RUN2/memory-proposals" "$(pal_run_dir run-3)"
    _proposal "$RUN1/memory-proposals/build-trap.md" build-trap "bun test needs --bail"
    _proposal "$RUN1/memory-proposals/ci-quirk.md"   ci-quirk   "CI runs old shellcheck"
    _proposal "$RUN2/memory-proposals/other.md"      other      "from run 2"
    HOST_REPO=/home/me/repos/foo
    MEM_DIR="$HOME/.claude/projects/-home-me-repos-foo/memory"
}

_proposal() { # <path> <name> <description>
    printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  type: project\n---\n\nbody of %s\n' "$2" "$3" "$2" > "$1"
}

@test "list: all runs, tab-separated, sorted by run then file; .triaged excluded" {
    mkdir -p "$RUN1/memory-proposals/.triaged"
    _proposal "$RUN1/memory-proposals/.triaged/done.md" done "already triaged"
    run pal_memory_proposals_list
    assert_success
    assert_line --index 0 "$(printf 'run-1\tbuild-trap.md\tbuild-trap — bun test needs --bail')"
    assert_line --index 1 "$(printf 'run-1\tci-quirk.md\tci-quirk — CI runs old shellcheck')"
    assert_line --index 2 "$(printf 'run-2\tother.md\tother — from run 2')"
    refute_output --partial "done"
}

@test "list: a single run; a run with none says so on stderr and exits 0" {
    run pal_memory_proposals_list run-2
    assert_success
    assert_output "$(printf 'run-2\tother.md\tother — from run 2')"
    run pal_memory_proposals_list run-3
    assert_success
    assert_output --partial "pal: no pending memory proposals"
}

@test "adopt: copies the file, creates MEMORY.md with the index line, moves the proposal to .triaged" {
    run pal_memory_proposal_adopt run-1 build-trap.md "$HOST_REPO"
    assert_success
    [ -f "$MEM_DIR/build-trap.md" ]
    run cat "$MEM_DIR/MEMORY.md"
    assert_line --index 0 "# Memory Index"
    assert_line "- [build-trap](build-trap.md) — bun test needs --bail"
    [ -f "$RUN1/memory-proposals/.triaged/build-trap.md" ]
    [ ! -f "$RUN1/memory-proposals/build-trap.md" ]
    # second adopt appends to the existing index, does not rewrite the header
    run pal_memory_proposal_adopt run-1 ci-quirk.md "$HOST_REPO"
    assert_success
    run grep -c '^# Memory Index' "$MEM_DIR/MEMORY.md"; assert_output "1"
    run grep -c '^- \[' "$MEM_DIR/MEMORY.md"; assert_output "2"
}

@test "adopt: refuses to overwrite an existing memory file and prints the diff" {
    mkdir -p "$MEM_DIR"
    printf -- '---\nname: build-trap\ndescription: old\nmetadata:\n  type: project\n---\n\nold body\n' > "$MEM_DIR/build-trap.md"
    run pal_memory_proposal_adopt run-1 build-trap.md "$HOST_REPO"
    assert_failure
    assert_output --partial "already exists"
    assert_output --partial "-old body"
    assert_output --partial "+body of build-trap"
    run cat "$MEM_DIR/build-trap.md"; assert_output --partial "old body"
    [ -f "$RUN1/memory-proposals/build-trap.md" ]      # still pending
}

@test "adopt: rejects missing name, name/filename mismatch, and a missing file — nothing written" {
    printf -- '---\ndescription: no name\n---\nbody\n' > "$RUN1/memory-proposals/noname.md"
    run pal_memory_proposal_adopt run-1 noname.md "$HOST_REPO"
    assert_failure; assert_output --partial "no 'name:'"
    _proposal "$RUN1/memory-proposals/wrong.md" right "mismatch"
    run pal_memory_proposal_adopt run-1 wrong.md "$HOST_REPO"
    assert_failure; assert_output --partial "does not match"
    run pal_memory_proposal_adopt run-1 ghost.md "$HOST_REPO"
    assert_failure; assert_output --partial "no such proposal"
    [ ! -d "$MEM_DIR" ]
}

@test "discard: moves to .triaged without touching host memory; missing file fails" {
    run pal_memory_proposal_discard run-1 ci-quirk.md
    assert_success
    [ -f "$RUN1/memory-proposals/.triaged/ci-quirk.md" ]
    [ ! -d "$MEM_DIR" ]
    run pal_memory_proposal_discard run-1 ci-quirk.md
    assert_failure
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tests/bats/bin/bats tests/test_memory_proposals.bats`
Expected: every test fails in `setup` (`lib/memory-proposals.sh: No such file`).

- [ ] **Step 3: Implement**

Create `lib/memory-proposals.sh`:

```bash
# lib/memory-proposals.sh
# shellcheck shell=bash
# Triage memory proposals written by pipeline phases. run-pipeline.sh copies
# <worktree>/.agent-data/memory-proposals/*.md to <runs>/<run-id>/memory-proposals/
# (bind-mounted /status). Nothing reaches ~/.claude/projects/<slug>/memory/
# unless a human adopts it here. Triaged files move to memory-proposals/.triaged/.

# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/memory-sync.sh"

# _pal_proposal_field <file> <key> — scalar frontmatter value (first match).
_pal_proposal_field() {
    local file="$1" key="$2"
    awk -v key="$key" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        NR > 1 && index($0, key ":") == 1 {
            sub("^" key ":[[:space:]]*", ""); print; exit
        }
    ' "$file"
}

# pal_memory_proposals_list [run-id]
pal_memory_proposals_list() {
    local only_run="${1:-}"
    local runs_dir run_dir run_id f name desc found=0
    runs_dir="$(pal_runs_dir)"
    [ -d "$runs_dir" ] || { echo "pal: no pending memory proposals" >&2; return 0; }
    for run_dir in "$runs_dir"/*/; do
        run_dir="${run_dir%/}"
        run_id="$(basename "$run_dir")"
        [ -n "$only_run" ] && [ "$run_id" != "$only_run" ] && continue
        [ -d "$run_dir/memory-proposals" ] || continue
        for f in "$run_dir"/memory-proposals/*.md; do
            [ -f "$f" ] || continue
            name="$(_pal_proposal_field "$f" name)"
            desc="$(_pal_proposal_field "$f" description)"
            printf '%s\t%s\t%s — %s\n' "$run_id" "$(basename "$f")" "${name:-?}" "${desc:-}"
            found=1
        done
    done
    [ "$found" -eq 1 ] || echo "pal: no pending memory proposals${only_run:+ for run $only_run}" >&2
    return 0
}

_pal_proposal_path() { # <run-id> <file> → path, or 1 if missing
    local p
    p="$(pal_run_dir "$1")/memory-proposals/$2"
    if [ ! -f "$p" ]; then
        echo "pal: no such proposal: $1/$2" >&2
        return 1
    fi
    printf '%s\n' "$p"
}

_pal_proposal_triage() { # <proposal-path>
    local dir
    dir="$(dirname "$1")/.triaged"
    mkdir -p "$dir"
    mv "$1" "$dir/"
}

# pal_memory_proposal_adopt <run-id> <file> <host-repo-path>
pal_memory_proposal_adopt() {
    local run_id="$1" file="$2" host_repo="$3"
    local src name desc slug mem_dir dest
    src="$(_pal_proposal_path "$run_id" "$file")" || return 1

    name="$(_pal_proposal_field "$src" name)"
    if [ -z "$name" ]; then
        echo "pal: $file has no 'name:' in its frontmatter — fix it or --discard" >&2
        return 1
    fi
    if [ "$name" != "${file%.md}" ]; then
        echo "pal: name '$name' does not match filename '$file' (expected ${name}.md)" >&2
        return 1
    fi
    desc="$(_pal_proposal_field "$src" description)"

    slug="$(pal_memory_slug "$host_repo")"
    mem_dir="${HOME}/.claude/projects/${slug}/memory"
    dest="$mem_dir/$file"
    if [ -e "$dest" ]; then
        echo "pal: $dest already exists — not overwriting. Diff (existing → proposal):" >&2
        diff -u "$dest" "$src" >&2 || true
        return 1
    fi

    mkdir -p "$mem_dir"
    cp "$src" "$dest"
    if [ ! -f "$mem_dir/MEMORY.md" ]; then
        printf '# Memory Index\n\n' > "$mem_dir/MEMORY.md"
    fi
    printf -- '- [%s](%s) — %s\n' "$name" "$file" "$desc" >> "$mem_dir/MEMORY.md"
    _pal_proposal_triage "$src"
    echo "pal: adopted $file → $dest (index line appended to MEMORY.md)"
}

# pal_memory_proposal_discard <run-id> <file>
pal_memory_proposal_discard() {
    local src
    src="$(_pal_proposal_path "$1" "$2")" || return 1
    _pal_proposal_triage "$src"
    echo "pal: discarded $2 (moved to .triaged/)"
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck -S info lib/memory-proposals.sh && ./tests/bats/bin/bats tests/test_memory_proposals.bats`
Expected: 6 tests, 0 failures. If the diff assertion fails, note the test checks `output` — `run` merges stderr into `$output`, so writing the diff to stderr is fine.

- [ ] **Step 5: Commit**

```bash
git add lib/memory-proposals.sh tests/test_memory_proposals.bats
git commit -m "feat(host): memory-proposal triage library (list/adopt/discard)"
```

---

### Task 4: `/pal-memory` skill and command

**Files:**
- Create: `skills/pal-memory/SKILL.md`, `commands/pal-memory.md`
- Test: `tests/test_skill_pal_memory.bats` (create)

**Interfaces:**
- Consumes: Task 3 functions; `pal_load_config` (`lib/config.sh`).
- Produces: `/pal-memory [run-id]`, `/pal-memory [run-id] --adopt <file>`, `/pal-memory [run-id] --discard <file>`. `--adopt`/`--discard` require the run-id. Host repo path is `git rev-parse --show-toplevel` of the cwd (same rule as `pal-implement`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_skill_pal_memory.bats` (same extraction pattern as `tests/test_skill_pal_workspace.bats`):

```bash
#!/usr/bin/env bats
# shellcheck shell=bash
# Smoke test for the /pal-memory skill: extracts the bash block from SKILL.md
# and drives list / adopt / discard against a temp HOME and runs dir.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"
    export GH_TOKEN=github_pat_fake

    SKILL_SCRIPT="$TMPHOME/pal-memory.sh"
    awk '
        /^```bash$/ { in_block=1; next }
        /^```$/     { if (in_block) { exit } }
        in_block    { print }
    ' "$REPO_ROOT/skills/pal-memory/SKILL.md" > "$SKILL_SCRIPT"

    # A host repo (cwd) so the skill can resolve the memory slug.
    REPO="$TMPHOME/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
    RUN_DIR="$XDG_DATA_HOME/sandbox-pal/runs/run-9/memory-proposals"; mkdir -p "$RUN_DIR"
    printf -- '---\nname: trap\ndescription: a trap\nmetadata:\n  type: project\n---\nbody\n' > "$RUN_DIR/trap.md"
    printf -- '---\nname: junk\ndescription: junk\nmetadata:\n  type: project\n---\nbody\n' > "$RUN_DIR/junk.md"
    cd "$REPO"
}

teardown() { rm -rf "$TMPHOME"; }

@test "pal-memory SKILL.md contains a bash block that sources memory-proposals.sh" {
    run test -s "$SKILL_SCRIPT"; assert_success
    run grep -Fq 'lib/memory-proposals.sh' "$SKILL_SCRIPT"; assert_success
}

@test "pal-memory (no args) lists pending proposals across runs" {
    run bash "$SKILL_SCRIPT"
    assert_success
    assert_output --partial "run-9"
    assert_output --partial "trap — a trap"
    assert_output --partial "junk — junk"
}

@test "pal-memory <run-id> --adopt <file> writes host memory for the cwd repo" {
    run bash "$SKILL_SCRIPT" run-9 --adopt trap.md
    assert_success
    local slug="${REPO//\//-}"
    [ -f "$HOME/.claude/projects/$slug/memory/trap.md" ]
    run grep -c 'trap.md' "$HOME/.claude/projects/$slug/memory/MEMORY.md"; assert_output "1"
    run bash "$SKILL_SCRIPT" run-9
    refute_output --partial "trap — a trap"
}

@test "pal-memory <run-id> --discard <file> moves it aside" {
    run bash "$SKILL_SCRIPT" run-9 --discard junk.md
    assert_success
    [ -f "$RUN_DIR/.triaged/junk.md" ]
    [ ! -d "$HOME/.claude/projects" ]
}

@test "pal-memory --adopt without a run-id, or an unknown flag, prints usage and fails" {
    run bash "$SKILL_SCRIPT" --adopt trap.md
    assert_failure; assert_output --partial "usage: pal-memory"
    run bash "$SKILL_SCRIPT" run-9 --bogus x
    assert_failure; assert_output --partial "usage: pal-memory"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tests/bats/bin/bats tests/test_skill_pal_memory.bats`
Expected: all fail (`SKILL.md` missing → empty script).

- [ ] **Step 3: Write the skill and command**

Create `skills/pal-memory/SKILL.md`:

````markdown
---
name: pal-memory
description: Triage memory proposals from sandbox-pal runs — list pending proposals, adopt one into this repo's host memory, or discard it. Host memory is never written automatically; this is the only path in.
---

# pal-memory

Pipeline phases run with a read-only copy of this repo's Claude Code memory.
When a phase learns something durable it writes a proposal to
`.agent-data/memory-proposals/<slug>.md`; the pipeline copies those to the
run directory (`~/.local/share/sandbox-pal/runs/<run-id>/memory-proposals/`)
and lists them in `status.json` (`memory_proposals`) and the PR body.

Usage:

- `/pal-memory`                           — list pending proposals across all runs
- `/pal-memory <run-id>`                  — list pending proposals for one run
- `/pal-memory <run-id> --adopt <file>`   — copy into `~/.claude/projects/<slug>/memory/` and index it in `MEMORY.md`
- `/pal-memory <run-id> --discard <file>` — move aside without adopting

`<slug>` is derived from the current repo's root (`git rev-parse --show-toplevel`),
so run this from inside the repo the proposal is about. Adopt refuses to
overwrite an existing memory file (it prints the diff instead) and rejects a
proposal whose `name:` does not match its filename.

```bash
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/memory-proposals.sh"

pal_load_config

usage() { echo "usage: pal-memory [run-id] [--adopt <file> | --discard <file>]" >&2; exit 2; }

run_id=""
action=""
file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --adopt|--discard)
            [ -n "${2:-}" ] || usage
            action="${1#--}"; file="$2"; shift 2 ;;
        --*) usage ;;
        *)
            [ -z "$run_id" ] || usage
            run_id="$1"; shift ;;
    esac
done

case "$action" in
    "")
        pal_memory_proposals_list "$run_id"
        ;;
    adopt)
        [ -n "$run_id" ] || usage
        host_repo="$(git -C . rev-parse --show-toplevel)"
        pal_memory_proposal_adopt "$run_id" "$file" "$host_repo"
        ;;
    discard)
        [ -n "$run_id" ] || usage
        pal_memory_proposal_discard "$run_id" "$file"
        ;;
esac
```

After adopting, tell the user what was written and that the index line was
appended to `MEMORY.md`; suggest opening the file if the description looks
like it needs editing.
````

Create `commands/pal-memory.md`:

```markdown
---
description: Use when the user wants to review, adopt, or discard memory proposals produced by sandbox-pal runs — "what did the agent learn", "pal memory proposals", "adopt that memory", "triage memory proposals", or after a PR body lists a "Memory proposals" section.
---

# /sandbox-pal:pal-memory

Triage memory proposals from sandbox-pal runs.

Usage: `/pal-memory [run-id] [--adopt <file> | --discard <file>]`

With no arguments, list pending proposals across all runs. Run from inside
the repository the proposals belong to (the host memory slug is derived from
the repo root).

Invoke the `pal-memory` skill.
```

- [ ] **Step 4: Run to verify they pass**

Run: `./tests/bats/bin/bats tests/test_skill_pal_memory.bats && claude plugin validate ~/repos/sandbox-pal`
Expected: 5 tests, 0 failures; `✔ Validation passed`.

- [ ] **Step 5: Commit**

```bash
git add skills/pal-memory commands/pal-memory.md tests/test_skill_pal_memory.bats
git commit -m "feat(host): /pal-memory skill to triage memory proposals"
```

---

### Task 5: Record the decision — design doc §9.5, §5.3, CHANGELOG; full check; PR; #30 comment

**Files:**
- Modify: `docs/superpowers/specs/2026-04-18-sandbox-pal-design.md` (§5.3 example at lines 162–193; insert §9.5 after §9.4, before `## 10.`)
- Modify: `CHANGELOG.md` (`## [Unreleased]`)

- [ ] **Step 1: Design doc §5.3**

In the §5.3 code block, replace the `# Review gate toggles (defaults: all true)` group through `AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1` with:

```bash
# Review gate toggles (defaults: true / true / 3 / 2)
AGENT_ADVERSARIAL_PLAN_REVIEW=true
AGENT_POST_IMPL_REVIEW=true
AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3
AGENT_TEST_GATE_MAX_RETRIES=2

# Per-phase invocation flags (phases: ADVERSARIAL_PLAN, IMPLEMENT, TEST_FIX,
# POST_IMPL_REVIEW, POST_IMPL_RETRY). All optional; budget is limitless unless set.
AGENT_BUDGET_USD=10                  # global cap; AGENT_BUDGET_USD_<PHASE> overrides
AGENT_BUDGET_USD_IMPLEMENT=8
AGENT_EFFORT_IMPLEMENT=high
AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW=  # empty disables that phase's --json-schema
AGENT_MCP_CONFIG=                    # path → --mcp-config + --strict-mcp-config
AGENT_STRICT_MCP=true                # --strict-mcp-config with no config file
AGENT_SESSION_PERSISTENCE=false      # default: --no-session-persistence
AGENT_ADD_DIRS=                      # extra --add-dir paths (space-separated)
```

- [ ] **Step 2: Design doc §9.5**

Insert after the §9.4 bullet list (before `## 10. Dependencies and reuse`):

```markdown
### 9.5 Execution mode: container-only (decision, #30)

**Decided 2026-08-29** (jnurre64/sandbox-pal#30; design in
`docs/superpowers/specs/2026-08-29-upstream-batch-adoption-design.md` §2.1).
sandbox-pal does **not** offer a host-native execution mode. Upstream
`sandbox-pal-action`'s orchestrator mode already covers "phases as `claude -p`
children on the operator's machine, inheriting everything"; duplicating it
here would dilute the one promise this project makes — credentials in a
named volume, phases contained.

Instead the environment gaps are closed deliberately inside the container
("the middle path"): *inherit identity, memory and skills; gate the tool
surface explicitly.*

| Channel | Mechanism |
|---|---|
| Identity / rules | `~/.config/sandbox-pal/container-CLAUDE.md` → container `~/.claude/CLAUDE.md` (`lib/container-rules.sh`) |
| Memory (read) | Host auto-memory copied to `/home/agent/memory/<host-slug>/`, root-owned and `go=rX`; `MEMORY.md` injected via `--append-system-prompt`, files readable via `--add-dir` (`lib/memory-sync.sh`, `AGENT_MEMORY_DIR`) |
| Memory (write) | Never direct. Phases write `.agent-data/memory-proposals/*.md`; the pipeline harvests them to the run dir; `/pal-memory` adopts or discards on the host |
| Skills | Opt-in by name: `PAL_SYNC_SKILLS=name,name` → `/home/agent/.claude/skills/<name>` (`lib/skills-sync.sh`); default empty |
| Tool surface | Per-phase `AGENT_ALLOWED_TOOLS_*`, `AGENT_PERMISSION_MODE_<PHASE>`, `AGENT_MCP_CONFIG` / `AGENT_STRICT_MCP` (`--strict-mcp-config`) |

Leftovers that are not part of this decision are tracked as follow-up issues
linked from #30 (rules staging, upstream #104).
```

- [ ] **Step 3: CHANGELOG**

Under `## [Unreleased]` → `### Added`, append:

```markdown
- **Container middle path (#30 decision: container-only, no host-native mode).** Host auto-memory now lands in the workspace at `/home/agent/memory/<host-slug>/` as a root-owned, read-only directory (`lib/memory-sync.sh`); the launcher passes `AGENT_MEMORY_DIR` so the runner injects `MEMORY.md` into the system prompt and exposes the files with `--add-dir`. Selected host skills sync in by name with `PAL_SYNC_SKILLS=name,name` (`lib/skills-sync.sh`; default empty). New `/pal-memory [run-id] [--adopt <file> | --discard <file>]` triages the memory proposals harvested to `~/.local/share/sandbox-pal/runs/<run-id>/memory-proposals/` — the only path by which agent learnings reach host memory. Design doc §9.5 records the decision.
```

Under `### Changed`, append:

```markdown
- Memory is no longer copied into the container's writable project slug (`~/.claude/projects/<run-slug>/memory`); the container's claude cannot auto-load or edit it.
```

- [ ] **Step 4: Full check**

Run: `shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/ && claude plugin validate ~/repos/sandbox-pal`
Expected: shellcheck silent; bats all green (the Docker-gated integration test skipped); `✔ Validation passed`.

- [ ] **Step 5: Commit, push, open the PR, record the decision on #30**

```bash
git add docs/superpowers/specs/2026-04-18-sandbox-pal-design.md CHANGELOG.md
git commit -m "docs: record the container-only execution-mode decision (#30) and the PR 2 changelog"
git push -u origin feature/31-middle-path
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh pr create --repo jnurre64/sandbox-pal \
  --title "feat(host): container middle path — read-only memory, skills sync, /pal-memory (#30 decision)" \
  --body "Part 2 of 3 for #31 — see docs/superpowers/specs/2026-08-29-upstream-batch-adoption-design.md §2.1, §2.3, §3.6.

- Memory: synced to /home/agent/memory/<host-slug> root-owned + go=rX; AGENT_MEMORY_DIR forwarded to the pipeline (runner from #32 injects MEMORY.md, --add-dir the files)
- Skills: PAL_SYNC_SKILLS=name,name opt-in sync into the workspace (default empty)
- /pal-memory: list / --adopt / --discard for the memory proposals harvested by #32
- Design doc §9.5 records the #30 decision (container-only; host-native is a non-goal); §5.3 shows the flag surface
- Tests: test_memory_sync (rewritten), test_skills_sync, test_memory_proposals, test_skill_pal_memory, launcher passthrough

PR 3 (README/docs for the flag surface, PAL_SYNC_SKILLS and /pal-memory; launcher passthrough test for the new AGENT_* knobs; .pal/config.env example) follows."
```

Then post the decision on #30 (replace `<pr-url>` with the URL `gh pr create` printed):

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh issue comment 30 --repo jnurre64/sandbox-pal --body "**Decision: container-only; host-native execution is an explicit non-goal.** The middle path is implemented in <pr-url> (read-only memory via AGENT_MEMORY_DIR, opt-in PAL_SYNC_SKILLS, /pal-memory for proposals) on top of #32 (runner/gates re-vendor incl. redaction, denial surfacing, --strict-mcp-config / per-phase permission modes). Recorded in the design doc §9.5. Acceptance items: decision ✔; vendoring sync ✔ (#32); container verification of redaction/denials — covered by tests/test_container_lib.bats and tests/test_run_pipeline.bats, live verification pending the first real run. Leftover before closing: rules staging (upstream #104) as a linked follow-up."
```

---

## Self-review against the spec

- §2.1 table: identity (unchanged, documented in §9.5) ✔; memory read-only + proposals ✔ (Tasks 1, 3, 4); skills opt-in by name ✔ (Task 2); tool surface (vendored runner, PR 1) documented in §5.3 ✔. "Finished is tracked": #30 comment names the leftover (rules staging) ✔.
- §2.3 `/pal-memory` semantics — list default all runs ✔; `--adopt` copies + appends index line ✔; `--discard` ✔; `.triaged/` ✔; nothing automatic ✔.
- §3.6 — destination `/home/agent/memory/<host-slug>/` ✔; `docker exec -u root chown/chmod` ✔; launcher `-e AGENT_MEMORY_DIR` ✔; `PAL_SYNC_MEMORIES=false` skips ✔; `pal_skills_sync_to_container` semantics (remove first, warn on missing, default empty, called from both launchers) ✔; `lib/memory-proposals.sh` three functions with the frontmatter/overwrite rules ✔.
- §3.7 — design-doc §9.5 and §5.3 ✔; README is PR 3 (unchanged here).
- §4 PR 2 tests — `test_memory_sync` (destination, read-only, `AGENT_MEMORY_DIR`) ✔; `test_skills_sync`, `test_memory_proposals`, `test_skill_pal_memory` ✔; launcher `AGENT_MEMORY_DIR` ✔.
- Type consistency: `pal_memory_proposal_adopt <run-id> <file> <host-repo-path>` used identically in Tasks 3 and 4; `pal_memory_slug` (existing) reused for the host slug; `AGENT_MEMORY_DIR` name matches `claude-runner.sh` from PR 1.
- Known gap accepted: the read-only bit is asserted via recorded `docker exec -u root … chmod` argv (the fake docker cannot exercise real permissions); the first live run verifies it.
