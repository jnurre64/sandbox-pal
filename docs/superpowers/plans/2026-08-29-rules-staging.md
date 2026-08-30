# Rules Staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vendor upstream `rules-staging.sh` (sandbox-pal-action#104) so a headless phase can propose edits to `.claude/rules/*.md` via staged copies under `.agent-data/rules/`, which the pipeline copies back and commits after the review loop.

**Architecture:** Claude Code has a built-in path guard: a headless phase cannot write under `.claude/**`. Upstream works around it with two functions — `stage_rules_files` (copy `.claude/rules/*.md` → `.agent-data/rules/` before the write phase) and `apply_rules_files` (copy back files that differ, commit them as `chore(agent): apply staged rules updates — <names>`). We vendor the file byte-for-byte into `image/opt/pal/lib/`, source it from `run-pipeline.sh`, call `stage_rules_files` once before the implement session (`.agent-data/` persists across the test-gate and review-retry sessions within a run and is git-excluded), and call `apply_rules_files` after the review loop, before `STATUS_COMMITS` is captured, so the rules commit is counted and pushed with the PR.

**Tech Stack:** bash, BATS-Core (`./tests/bats/bin/bats`), shellcheck.

**Spec:** https://github.com/jnurre64/sandbox-pal/issues/35#issuecomment-5466031252 (handoff comment) + upstream source `~/repos/sandbox-pal-action` at `04cef68`.

## Global Constraints

- Upstream source of truth: `git -C ~/repos/sandbox-pal-action show 04cef68:<path>`. `rules-staging.sh` is vendored **verbatim** — zero local edits (`UPSTREAM.md` row says `none`).
- Prompts stay byte-identical to upstream apart from the edits already enumerated in `UPSTREAM.md`. Upstream `post-impl-retry.md` / `test-fix.md` at `04cef68` do **not** mention rules staging, so we add nothing to them.
- Before every commit: `shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/` from the repo root. Both must be clean.
- Container-only: staging and apply both happen inside the worktree in the container; no host-side involvement.
- `.agent-data/` stays git-excluded (`worktree.sh` adds it to `info/exclude`); commits use explicit paths.
- Existing e2e tests in `tests/test_run_pipeline.bats` must pass unchanged (repos without `.claude/rules/` hit the no-op path).
- Branch: `feature/35-rules-staging`. Final PR title: `feat(container): vendor rules staging so phases can propose .claude/rules edits (upstream #104)`, body `Closes #35`.

---

### Task 1: Vendor `rules-staging.sh` with host-runnable BATS tests

**Files:**
- Create: `image/opt/pal/lib/rules-staging.sh` (verbatim copy of `04cef68:scripts/lib/rules-staging.sh`)
- Modify: `tests/test_helper/container-lib.bash` (`container_lib_source` sources the new lib)
- Test: `tests/test_container_lib.bats` (append a `rules staging` section)

**Interfaces:**
- Consumes: fixture globals `WORKTREE_DIR` (a real git repo with identity set), `log` (from the fixture on the host / `run-pipeline.sh` in the container), `git`.
- Produces: `stage_rules_files` (no args, always returns 0), `apply_rules_files` (no args, always returns 0), globals `RULES_SOURCE_DIR=".claude/rules"`, `RULES_STAGING_DIR=".agent-data/rules"`, `RULES_APPLIED` (space-separated applied basenames, `""` when nothing applied). Task 2 relies on all of these.

- [x] **Step 1: Write the failing tests**

Append to `tests/test_container_lib.bats` (after the `worktree` section at the end of the file):

```bash
# ── rules staging (upstream #104) ───────────────────────────────

_seed_rules_file() {
    # $1 = name, $2 = content. Commits into the fixture worktree.
    mkdir -p "$WORKTREE_DIR/.claude/rules"
    printf '%s\n' "$2" > "$WORKTREE_DIR/.claude/rules/$1"
    git -C "$WORKTREE_DIR" add -A
    git -C "$WORKTREE_DIR" commit -q -m "add rules $1"
}

@test "rules: stage_rules_files copies .claude/rules/*.md into .agent-data/rules/" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    [ -f "$WORKTREE_DIR/.agent-data/rules/style.md" ]
    run cat "$WORKTREE_DIR/.agent-data/rules/style.md"; assert_output "original rule text"
    run cat "$LOG_FILE"; assert_output --partial "Staged 1 rules file(s)"
}

@test "rules: stage_rules_files is a no-op when the repo has no .claude/rules directory" {
    container_lib_source
    stage_rules_files
    [ ! -d "$WORKTREE_DIR/.agent-data/rules" ]
}

@test "rules: apply_rules_files copies back a modified staged file and commits it" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    printf 'edited by the phase\n' > "$WORKTREE_DIR/.agent-data/rules/style.md"
    apply_rules_files
    run cat "$WORKTREE_DIR/.claude/rules/style.md"; assert_output "edited by the phase"
    run git -C "$WORKTREE_DIR" log -1 --format=%s
    assert_output "chore(agent): apply staged rules updates — style.md"
    [ "$RULES_APPLIED" = "style.md" ]
    run git -C "$WORKTREE_DIR" status --porcelain; assert_output ""   # nothing left dirty
}

@test "REGRESSION upstream v1.2.0: a staged file with no counterpart in .claude/rules/ is not applied" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    printf 'invented by the phase\n' > "$WORKTREE_DIR/.agent-data/rules/invented.md"
    apply_rules_files
    [ ! -f "$WORKTREE_DIR/.claude/rules/invented.md" ]
    [ -z "$RULES_APPLIED" ]
    run cat "$LOG_FILE"; assert_output --partial "no counterpart"
}

@test "rules: apply_rules_files ignores staged names outside the allow-list pattern" {
    container_lib_source
    _seed_rules_file "bad name.md" "spaced original"
    stage_rules_files
    printf 'edited\n' > "$WORKTREE_DIR/.agent-data/rules/bad name.md"
    apply_rules_files
    run cat "$WORKTREE_DIR/.claude/rules/bad name.md"; assert_output "spaced original"
    run cat "$LOG_FILE"; assert_output --partial "outside the allow-list pattern"
}

@test "rules: apply_rules_files makes no commit when nothing differs" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    before=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
    apply_rules_files
    [ "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" = "$before" ]
    [ -z "$RULES_APPLIED" ]
}

@test "rules: vendored rules-staging.sh is byte-identical to upstream 04cef68" {
    if [ ! -d "$HOME/repos/sandbox-pal-action/.git" ]; then skip "upstream clone not present"; fi
    run diff <(git -C "$HOME/repos/sandbox-pal-action" show 04cef68:scripts/lib/rules-staging.sh) "$LIB_DIR/rules-staging.sh"
    assert_success
}
```

Note: the fixture's `container_lib_setup` already creates `WORKTREE_DIR` as a git repo on `main` with identity set and an initial empty commit, so `_seed_rules_file` only needs to add and commit.

- [x] **Step 2: Make the fixture source the new lib**

In `tests/test_helper/container-lib.bash`, `container_lib_source` becomes:

```bash
container_lib_source() {
    # shellcheck disable=SC1091
    . "$LIB_DIR/claude-runner.sh"
    # shellcheck disable=SC1091
    . "$LIB_DIR/review-gates.sh"
    # shellcheck disable=SC1091
    . "$LIB_DIR/rules-staging.sh"
}
```

- [x] **Step 3: Run the tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_container_lib.bats -f "rules"`
Expected: every existing test that calls `container_lib_source` now fails too (file missing) — that's fine at this step; the 7 new `rules` tests FAIL with `No such file or directory` for `rules-staging.sh`.

- [x] **Step 4: Vendor the file verbatim**

```bash
git -C ~/repos/sandbox-pal-action show 04cef68:scripts/lib/rules-staging.sh > image/opt/pal/lib/rules-staging.sh
diff <(git -C ~/repos/sandbox-pal-action show 04cef68:scripts/lib/rules-staging.sh) image/opt/pal/lib/rules-staging.sh && echo IDENTICAL
```

Do **not** edit the file. Check whether the other vendored libs are executable (`ls -l image/opt/pal/lib/`) and match the mode (`chmod` accordingly) — mode is not part of the diff check.

- [x] **Step 5: Run the tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_container_lib.bats`
Expected: all PASS, including the 7 new `rules` tests.

- [x] **Step 6: Lint + full suite, then commit**

```bash
shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/
git add image/opt/pal/lib/rules-staging.sh tests/test_helper/container-lib.bash tests/test_container_lib.bats
git commit -m "feat(container): vendor rules-staging.sh from upstream 04cef68 with host-runnable tests

Verbatim copy of scripts/lib/rules-staging.sh (sandbox-pal-action#104).
Not yet wired into the pipeline."
```

---

### Task 2: Wire staging/apply into `run-pipeline.sh` with an e2e test

**Files:**
- Modify: `image/opt/pal/run-pipeline.sh` — source line (~line 170), `stage_rules_files` before implement (~line 247), `apply_rules_files` after the review loop (~line 285), `rules_applied` in `write_status` (~lines 93–135)
- Test: `tests/test_run_pipeline.bats` (append one e2e case)

**Interfaces:**
- Consumes: `stage_rules_files`, `apply_rules_files`, `RULES_APPLIED` from Task 1.
- Produces: `status.json` gains `rules_applied` (JSON array of basenames, `[]` when none). Task 3 documents it.

- [x] **Step 1: Write the failing e2e test**

Append to `tests/test_run_pipeline.bats`:

```bash
@test "implement: staged .agent-data/rules edit is applied as a chore(agent) commit, counted, pushed, and listed in status.json" {
    # Seed a rules file on origin/main so stage_rules_files has something to stage.
    mkdir -p "$seed/.claude/rules"
    printf 'original rule\n' > "$seed/.claude/rules/x.md"
    git -C "$seed" add .claude/rules/x.md
    git -C "$seed" -c user.email=t@e -c user.name=t commit -q -m "add rules"
    git -C "$seed" push -q origin HEAD:main

    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" \
        'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"; test -f .agent-data/rules/x.md || exit 9; printf "edited rule\n" > .agent-data/rules/x.md'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[]}')"

    run "$PIPELINE" implement owner/repo 42
    assert_success

    S="$STATUS_DIR/status.json"
    run jq -r '.outcome' "$S"; assert_output "success"
    run jq -r '.commits | length' "$S"; assert_output "3"          # feat + ledger + rules
    run jq -c '.rules_applied' "$S"; assert_output '["x.md"]'
    run git -C "$ORIGIN" log --format=%s agent/issue-42
    assert_line --index 0 "chore(agent): apply staged rules updates — x.md"
    run git -C "$ORIGIN" show agent/issue-42:.claude/rules/x.md; assert_output "edited rule"
    run git -C "$ORIGIN" ls-tree -r --name-only agent/issue-42; refute_output --partial ".agent-data"
}

@test "implement: rules_applied is an empty array when the repo has no .claude/rules" {
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" 'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[]}')"
    run "$PIPELINE" implement owner/repo 42
    assert_success
    run jq -c '.rules_applied' "$STATUS_DIR/status.json"; assert_output '[]'
}
```

Ordering note: `apply_rules_files` runs after the review loop, so the rules commit is the newest commit on the branch (after the ledger commit) — hence `--index 0` on the log.

- [x] **Step 2: Run the tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_run_pipeline.bats -f "rules"`
Expected: first test FAILS (the fake implement session exits 9 because `.agent-data/rules/x.md` was never staged → `empty_diff`/failure); second FAILS with `.rules_applied` = `null`.

- [x] **Step 3: Source the lib in `run-pipeline.sh`**

In the `# --- Source lib files` block, add after `. "$LIB_DIR/review-gates.sh"`:

```bash
. "$LIB_DIR/rules-staging.sh"
```

- [x] **Step 4: Stage before implement**

Immediately before `set_heartbeat "implement"`:

```bash
# Stage .claude/rules/*.md into .agent-data/rules/ so the phase can propose
# rule edits despite Claude Code's .claude/** write guard (upstream #104).
# Once per run: .agent-data/ persists across the test-gate and review-retry
# sessions and is git-excluded by setup_worktree.
stage_rules_files
```

- [x] **Step 5: Apply after the review loop, before `STATUS_COMMITS`**

Replace:

```bash
if [ "$review_rc" -eq 1 ]; then
    exit 1
fi

end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
STATUS_COMMITS=...
```

with:

```bash
if [ "$review_rc" -eq 1 ]; then
    exit 1
fi

# Copy back staged rules edits that differ and commit them (counted in
# STATUS_COMMITS, pushed with the branch).
apply_rules_files

end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
STATUS_COMMITS=...
```

(Keep the existing `STATUS_COMMITS=` line untouched.)

- [x] **Step 6: Report `rules_applied` in `write_status`**

In `write_status`, after the `proposals` block and before the `jq -n`:

```bash
    local rules_applied='[]'
    if [ -n "${RULES_APPLIED:-}" ]; then
        rules_applied=$(printf '%s\n' "$RULES_APPLIED" | tr ' ' '\n' | jq -Rsc 'split("\n") | map(select(. != ""))')
    fi
```

Add `--argjson rules_applied "$rules_applied" \` next to `--argjson proposals`, and in the jq object add `rules_applied: $rules_applied,` after `memory_proposals: $proposals,`.

`RULES_APPLIED` is defined by the sourced lib, but `write_status` runs from the EXIT trap and can fire before the lib is sourced (e.g. an early failure), so the `${RULES_APPLIED:-}` default is required under `set -u`.

- [x] **Step 7: Run the tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_run_pipeline.bats`
Expected: all PASS, including both new tests and the unchanged happy-path (`.commits | length` still `2`).

- [x] **Step 8: Lint + full suite, then commit**

```bash
shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/
git add image/opt/pal/run-pipeline.sh tests/test_run_pipeline.bats
git commit -m "feat(container): stage .claude/rules before implement and apply staged edits after review

stage_rules_files runs once before the implement session; apply_rules_files
runs after the review loop so the chore(agent) commit is counted in
STATUS_COMMITS and pushed with the PR. status.json gains rules_applied."
```

---

### Task 3: Upstream bookkeeping, docs and CHANGELOG

**Files:**
- Modify: `UPSTREAM.md` (Libraries table + "Deliberately not vendored")
- Modify: `scripts/diff-upstream.sh:21` (MAP entry)
- Modify: `docs/configuration.md:103-107` ("Identity and rules")
- Modify: `CHANGELOG.md` (Unreleased → Added)
- Test: `tests/test_container_lib.bats` (the byte-identical test from Task 1 already covers the file; add a MAP check)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing; documentation only.

- [x] **Step 1: Write the failing test**

Append to the `rules staging` section of `tests/test_container_lib.bats`:

```bash
@test "rules: diff-upstream.sh MAP and UPSTREAM.md track rules-staging.sh" {
    run grep -c '\["image/opt/pal/lib/rules-staging.sh"\]="scripts/lib/rules-staging.sh"' "$REPO_ROOT/scripts/diff-upstream.sh"
    assert_output "1"
    run grep -c '^| `image/opt/pal/lib/rules-staging.sh` | `scripts/lib/rules-staging.sh` | none |' "$REPO_ROOT/UPSTREAM.md"
    assert_output "1"
    run grep -c 'rules-staging.sh.*follow-up issue' "$REPO_ROOT/UPSTREAM.md"
    assert_output "0"
}
```

- [x] **Step 2: Run it to verify it fails**

Run: `./tests/bats/bin/bats tests/test_container_lib.bats -f "diff-upstream"`
Expected: FAIL (`grep -c` prints `0` for the first two).

- [x] **Step 3: `scripts/diff-upstream.sh`**

Add to `MAP` after the `review-gates.sh` line:

```bash
    ["image/opt/pal/lib/rules-staging.sh"]="scripts/lib/rules-staging.sh"
```

Then run `scripts/diff-upstream.sh` and confirm `rules-staging.sh` reports identical (other rows may still report their enumerated local diffs — that is the pre-existing state).

- [x] **Step 4: `UPSTREAM.md`**

In the Libraries table add a row after `review-gates.sh`:

```markdown
| `image/opt/pal/lib/rules-staging.sh` | `scripts/lib/rules-staging.sh` | none |
```

In "Deliberately not vendored", delete the line:

```markdown
- `rules-staging.sh` (#104) — follow-up issue; the prompt rule text is kept.
```

- [x] **Step 5: `docs/configuration.md`**

Under `## Identity and rules`, after the existing `/pal-workspace edit-rules` paragraph, add:

```markdown
Repo-level rules (`<project>/.claude/rules/*.md`) can be updated by a run.
Claude Code blocks headless writes under `.claude/`, so the pipeline stages
copies under `.agent-data/rules/` before the implement session, and after the
review loop copies back any staged file that changed and commits it as
`chore(agent): apply staged rules updates — <names>` on the PR branch. Only
files that already exist in `.claude/rules/` with names matching
`^[A-Za-z0-9._-]+\.md$` are applied; a phase cannot invent a rules file.
Applied names appear as `rules_applied` in `status.json`.
```

- [x] **Step 6: `CHANGELOG.md`**

Under `## [Unreleased]` → `### Added`, after the "Memory proposals" bullet, add:

```markdown
- **Rules staging** (vendored `rules-staging.sh`, upstream #104): `.claude/rules/*.md` are staged to `.agent-data/rules/` before the implement session; edits to the staged copies are applied and committed by the pipeline as `chore(agent): apply staged rules updates — <names>` after the review loop. `status.json` gains `rules_applied`.
```

- [x] **Step 7: Run the test to verify it passes**

Run: `./tests/bats/bin/bats tests/test_container_lib.bats -f "rules"`
Expected: all PASS.

- [x] **Step 8: Lint + full suite, then commit**

```bash
shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/
git add UPSTREAM.md scripts/diff-upstream.sh docs/configuration.md CHANGELOG.md tests/test_container_lib.bats
git commit -m "docs: track rules-staging.sh in UPSTREAM.md and diff-upstream; document rules_applied"
```

---

### Task 4: Open the PR

- [x] **Step 1: Push and open**

```bash
git push -u origin feature/35-rules-staging
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh pr create --repo jnurre64/sandbox-pal \
  --title "feat(container): vendor rules staging so phases can propose .claude/rules edits (upstream #104)" \
  --body "Closes #35"
```

- [x] **Step 2: Confirm CI is green** (`gh pr checks --watch` with the same token).

---

## Self-review

- **Spec coverage:** vendor lib ✔ (T1); stage before implement ✔ (T2.4); apply after review loop, before `STATUS_COMMITS`/push ✔ (T2.5); `rules_applied` in status.json ✔ (T2.6); prompts untouched — upstream `post-impl-retry`/`test-fix` at `04cef68` have no rules text ✔ (Global Constraints); tests ported 6/7 + e2e ✔ (T1, T2); `UPSTREAM.md`, `diff-upstream.sh`, `configuration.md`, `CHANGELOG` ✔ (T3); PR ✔ (T4). `revise` event shares the implement block → staged for free ✔.
- **Placeholders:** none.
- **Consistency:** `RULES_APPLIED` / `rules_applied` / commit message `chore(agent): apply staged rules updates — <names>` used identically across T1–T3.
