# oss-health Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a standalone global Claude Code skill at `~/.claude/skills/oss-health/SKILL.md` that audits open source repository best practices, scaffolds missing files, and guides users through UI-only steps — then apply it to validate and fix claude-pal.

**Architecture:** A single SKILL.md with five clearly-delimited sections (files, readme, github, ci, releases). Arg routing at the top lets users run a full audit or jump to one section. Each section has tiered checks (essential/important/polish), reports status with ✓/✗/⚠, and either creates missing files or prints numbered walkthrough steps for UI-only items.

**Tech Stack:** Claude Code skill (Markdown instructions), bash for git commands run during checks, GitHub Actions YAML for scaffolded workflows.

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `~/.claude/skills/oss-health/SKILL.md` | Create | The skill — all five sections |

No other files. After the skill is built, Tasks 7–9 apply it to claude-pal, which will create several files in that repo (CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, .github/ tree, etc.).

---

## Task 1: Skill skeleton — frontmatter, arg routing, context gathering, report format

**Files:**
- Create: `~/.claude/skills/oss-health/SKILL.md`

- [ ] **Step 1: Create the skill directory and initial SKILL.md**

```bash
mkdir -p ~/.claude/skills/oss-health
```

Write `~/.claude/skills/oss-health/SKILL.md` with this content:

````markdown
---
name: oss-health
description: Audit open source repository best practices and scaffold missing files. Reports gaps by tier (essential/important/polish) for: community health files (LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY), README quality (badges, sections), .github/ setup (CI, templates, dependabot), CI/CD automation, and release discipline. Offers to fix auto-fixable items inline or walks through UI-only steps. Trigger on: "open source repo health", "missing contributing guidelines", "repo hygiene", "oss checklist", "open source best practices", "is my repo open source ready"
---

# OSS Health Check

You are performing an open source repository health audit. You will check the current repository against a tiered checklist, report status for each item, and either scaffold fixes or guide the user through manual steps.

## Startup

1. Check `args`:
   - If empty: run all five sections in order (files → readme → github → ci → releases)
   - If a valid category name: jump to that section only
   - Valid categories: `files`, `readme`, `github`, `ci`, `releases`
   - If an unrecognized arg: print `Unknown category '<arg>'. Valid categories: files, readme, github, ci, releases` and stop.

2. Gather repo context by reading these files if they exist:
   - README.md — project name (first H1), description (text under H1), any existing badges
   - package.json / plugin.json / pyproject.toml / Cargo.toml — name, description, author
   - LICENSE — license type (MIT, Apache-2.0, etc.)
   - Run `git config user.email` for contact email, `git remote get-url origin` for repo URL
   - CODEOWNERS or package.json author field — GitHub username

   Store: `PROJECT_NAME`, `PROJECT_DESCRIPTION`, `STACK` (shell/bats, node, python, rust, generic), `LICENSE_TYPE`, `CONTACT_EMAIL`, `GITHUB_USERNAME`, `REPO_URL`, `GITHUB_REPO` (owner/name extracted from remote URL).

3. At the start of a **full run** (no args), ask:
   > "Fix all auto-fixable gaps automatically? (y = fix all without prompting per item, n = ask before each fix)"

   Store the answer as `FIX_ALL`. Per-section runs (with an arg) always ask per-item.

## Report Format

For each checklist item, prefix the status:
- `✓` — present and adequate
- `✗` — missing or absent
- `⚠` — present but needs improvement

After all checks in a section, print: `Section complete: N✓ M✗ P⚠`

At the end of a full run, print:

```
=== OSS Health Summary ===
files:    N✓ M✗ P⚠
readme:   N✓ M✗ P⚠
github:   N✓ M✗ P⚠
ci:       N✓ M✗ P⚠
releases: N✓ M✗ P⚠

Auto-fixed this run: [list of files created/modified, or "none"]
Still needs attention: [list of remaining gaps with tiers]
Manual steps required: [list if any UI walkthroughs were printed, or "none"]
```

## Offer Fix Pattern

When a gap has an auto-fix available:
- If `FIX_ALL` is `y`: fix immediately, print `→ Created <file>` or `→ Updated <file>`
- Otherwise: print `→ Fix this now? (y/n)` and wait for response before writing anything

Never write files without confirmation (explicit `y` or `FIX_ALL` consent).
````

- [ ] **Step 2: Verify the file was created**

```bash
cat ~/.claude/skills/oss-health/SKILL.md | head -20
```

Expected: frontmatter block with `name: oss-health` visible.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude && git add skills/oss-health/SKILL.md && git commit -m "feat(skill): add oss-health skeleton with arg routing and context gathering"
```

(If `~/.claude` is not a git repo, skip the commit — the file is still usable.)

---

## Task 2: Implement `files` section

**Files:**
- Modify: `~/.claude/skills/oss-health/SKILL.md` — append Section: files

- [ ] **Step 1: Append the `files` section to SKILL.md**

Append the following to `~/.claude/skills/oss-health/SKILL.md`:

````markdown

---

## Section: files

Check for community health files at the repo root. Use Glob to check existence.

### Tier 1 — Essential

**LICENSE**
- Check: `LICENSE` or `LICENSE.md` or `LICENSE.txt` exists at repo root
- If missing: `✗ LICENSE — no license file found`
  - Fix: Ask user which license (MIT / Apache-2.0 / GPL-3.0 / other). Generate the appropriate SPDX license text with current year and author name from git config. Write to `LICENSE`.
- If present: `✓ LICENSE (detected: <type>)`

**CONTRIBUTING.md**
- Check: `CONTRIBUTING.md` exists
- If missing: `✗ CONTRIBUTING.md — no contributor guidelines`
  - Fix: Generate `CONTRIBUTING.md` using repo context. Include:
    - Brief intro ("Thank you for contributing to PROJECT_NAME!")
    - Fork → feature branch → PR workflow
    - Branch naming convention (kebab-case: `feat/`, `fix/`, `docs/`)
    - Commit style (conventional commits: feat, fix, docs, test, chore)
    - How to run tests (use detected stack: `bats tests/` for shell/bats, `npm test` for node, `pytest` for python)
    - How to run linting (e.g. `shellcheck $(find . -name '*.sh')` for shell)
    - PR checklist (tests pass, lint clean, CHANGELOG updated for user-facing changes)
    - Issue reporting guidance (use GitHub Issues, search before filing)
- If present: `✓ CONTRIBUTING.md`

**CODE_OF_CONDUCT.md**
- Check: `CODE_OF_CONDUCT.md` exists
- If missing: `✗ CODE_OF_CONDUCT.md — no community conduct expectations`
  - Fix: Generate Contributor Covenant v2.1 full text. Replace `[INSERT CONTACT METHOD]` with `CONTACT_EMAIL` if found, otherwise leave as `[your-email@example.com]` with a note to fill it in. Write to `CODE_OF_CONDUCT.md`.
- If present: `✓ CODE_OF_CONDUCT.md`

**SECURITY.md**
- Check: `SECURITY.md` exists
- If missing: `✗ SECURITY.md — no vulnerability disclosure process`
  - Fix: Generate `SECURITY.md` with:
    - Supported versions table stubbed from the current version in CHANGELOG.md or plugin.json/package.json; mark current minor as supported, older versions as unsupported
    - Reporting section: "Please do not report security vulnerabilities through public GitHub issues. Use GitHub's private security advisory feature: `REPO_URL/security/advisories/new`"
    - Response timeline: acknowledge within 48 hours, patch within 90 days of confirmation
    - Brief security considerations section relevant to detected stack (e.g. for shell: "do not pass untrusted input to eval or unquoted expansions")
- If present: `✓ SECURITY.md`

### Tier 2 — Important

**CHANGELOG.md**
- Check: `CHANGELOG.md` exists
- If missing: `✗ CHANGELOG.md [Tier 2] — no changelog`
  - Fix: Generate a Keep a Changelog stub:
    ```
    # Changelog
    All notable changes to PROJECT_NAME will be documented here.
    This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

    ## [Unreleased]
    ```
- If present: `✓ CHANGELOG.md`

**.gitignore**
- Check: `.gitignore` exists. Read its content.
- Determine missing patterns based on STACK:
  - All stacks: `*.log`, `*.tmp`, `.DS_Store`, `Thumbs.db`
  - Node: `node_modules/`, `dist/`, `.env`
  - Python: `__pycache__/`, `*.pyc`, `.venv/`, `dist/`, `.env`
  - Rust: `target/`
- If `.gitignore` missing entirely: `✗ .gitignore [Tier 2] — no gitignore`
  - Fix: Create `.gitignore` with all applicable patterns above.
- If present but missing patterns: `⚠ .gitignore [Tier 2] — missing: <list>`
  - Fix: Append only the missing patterns to the existing file.
- If adequate: `✓ .gitignore`

### Tier 3 — Polish

**CITATION.cff**
- Check: `CITATION.cff` exists
- If missing: `✗ CITATION.cff [Tier 3] — no machine-readable citation metadata`
  - Fix: Generate minimal `CITATION.cff`:
    ```yaml
    cff-version: 1.2.0
    message: "If you use this software, please cite it as below."
    type: software
    title: PROJECT_NAME
    abstract: PROJECT_DESCRIPTION
    authors:
      - name: GITHUB_USERNAME
        email: CONTACT_EMAIL
    repository-code: REPO_URL
    license: LICENSE_TYPE
    ```
    Omit any field where the value could not be determined.
- If present: `✓ CITATION.cff`

**MAINTAINERS / AUTHORS**
- Check: `MAINTAINERS`, `MAINTAINERS.md`, `AUTHORS`, or `AUTHORS.md` exists
- If missing AND `.github/CODEOWNERS` also missing: `✗ MAINTAINERS [Tier 3] — no maintainer file or CODEOWNERS`
  - Fix: Create `MAINTAINERS.md` with one line: `AUTHOR_NAME <CONTACT_EMAIL>` from git config.
- If missing but CODEOWNERS exists: `✓ MAINTAINERS — covered by CODEOWNERS`
- If present: `✓ MAINTAINERS / AUTHORS`
````

- [ ] **Step 2: Smoke-test the files section on claude-pal**

In a Claude Code session with the skill loaded, run:
```
/oss-health files
```
on the claude-pal repo. Expected: Claude reports `✗ CONTRIBUTING.md`, `✗ CODE_OF_CONDUCT.md`, `✗ SECURITY.md`, `✓ LICENSE`, `✓ CHANGELOG.md`, `✓ .gitignore`, `✗ CITATION.cff`.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude && git add skills/oss-health/SKILL.md && git commit -m "feat(skill): add oss-health files section"
```

---

## Task 3: Implement `readme` section

**Files:**
- Modify: `~/.claude/skills/oss-health/SKILL.md` — append Section: readme

- [ ] **Step 1: Append the `readme` section to SKILL.md**

Append the following to `~/.claude/skills/oss-health/SKILL.md`:

````markdown

---

## Section: readme

Check README.md content quality. Read the full file before checking.

### Tier 1 — Essential

**File exists**
- Check: `README.md` or `README` exists at repo root
- If missing: `✗ README.md — no README`
  - Fix: Generate a minimal `README.md`:
    ```markdown
    # PROJECT_NAME

    PROJECT_DESCRIPTION

    ## Installation

    <!-- Add installation steps here -->

    ## Usage

    <!-- Add usage examples here -->

    ## Contributing

    See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

    ## License

    This project is licensed under the LICENSE_TYPE License — see [LICENSE](LICENSE) for details.
    ```
  - After creating: note "README created — run `/oss-health github` to scaffold a CI workflow, then come back to add status badges."
  - Stop remaining readme checks (all require the file to exist).
- If present: continue checks.

**Has project description**
- Check: README has at least one paragraph of descriptive text (not just a title line and badges)
- If absent: `⚠ README — no project description found`
  - Fix: Ask the user for a 1–2 sentence description, then insert it below the H1 title.
- If present: `✓ README has description`

**Has install/usage section**
- Check: README contains a heading matching `/install|getting.started|quick.start|usage/i`
- If absent: `⚠ README — no install or usage section`
  - Note only (cannot auto-generate meaningful install steps): "Add an `## Installation` or `## Getting Started` section describing how to set up the project."
- If present: `✓ README has install/usage section`

### Tier 2 — Important

**License badge**
- Check: README contains a license badge (look for `shields.io` URL with "license" in text, or `img.shields.io/badge/License`)
- If missing: `✗ README — no license badge [Tier 2]`
  - Fix: Insert at the top of README (immediately after the H1 title line, before description text):
    - MIT: `[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)`
    - Apache-2.0: `[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)`
    - GPL-3.0: `[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)`
    - Other: `[![License](https://img.shields.io/badge/License-LICENSE_TYPE-lightgrey.svg)](LICENSE)`
- If present: `✓ README has license badge`

**CI/test status badge**
- Check: README contains a workflow status badge (look for `github/GITHUB_REPO/actions/workflows` or `actions/workflows` in any image URL)
- If missing: `✗ README — no CI status badge [Tier 2]`
  - Only offer fix if a `.github/workflows/` file exists. If so:
    - Detect the primary CI workflow filename (prefer `ci.yml`)
    - Insert badge at top of README (with other badges):
      `[![CI](https://github.com/GITHUB_REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/GITHUB_REPO/actions/workflows/ci.yml)`
  - If no workflow exists yet: note "Run `/oss-health github` first to scaffold a CI workflow, then re-run `/oss-health readme` to add the badge."
- If present: `✓ README has CI badge`

**Contributing section or link**
- Check: README contains a heading matching `/contributing/i` or a link to `CONTRIBUTING.md`
- If missing: `⚠ README — no contributing section [Tier 2]`
  - Fix: Append a `## Contributing` section before the `## License` section (or at end if no license section):
    ```markdown
    ## Contributing

    See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.
    ```
- If present: `✓ README has contributing section`

**License section**
- Check: README contains a heading matching `/^##\s+licen/im`
- If missing: `⚠ README — no license section [Tier 2]`
  - Fix: Append at end of README:
    ```markdown
    ## License

    This project is licensed under the LICENSE_TYPE License — see [LICENSE](LICENSE) for details.
    ```
- If present: `✓ README has license section`

### Tier 3 — Polish

**Hero image or screenshot**
- Check: README contains an `<img` tag or `![]()` image reference in the first 25 lines
- If missing: `✗ README — no hero image or screenshot [Tier 3]`
  - Note only: "Consider adding a logo, screenshot, or diagram near the top of the README to help visitors understand the project at a glance."
- If present: `✓ README has hero image`

**Disclaimer for community tools**
- Check: if README description mentions any well-known third-party product names (Claude, Anthropic, GitHub, etc.), check whether it also contains "not affiliated", "community project", or "unofficial"
- If product names present but no disclaimer: `⚠ README — consider adding a disclaimer if this is a community/unofficial project [Tier 3]`
  - Note: "Example: 'This is an independent community project and is not affiliated with or endorsed by <Company>.'"
- If disclaimer present or no third-party names detected: `✓ README disclaimer`

**Link to full docs**
- Check: README links to a `docs/` directory or external documentation site
- Also check: `docs/` directory exists with at least one `.md` file
- If `docs/` exists but README doesn't link to it: `⚠ README — docs/ directory exists but README doesn't link to it [Tier 3]`
  - Fix: Append a `## Documentation` section:
    ```markdown
    ## Documentation

    Full documentation is in the [docs/](docs/) directory.
    ```
- If neither docs nor link: `✗ README — no docs link [Tier 3]` (informational only)
- If present: `✓ README links to docs`
````

- [ ] **Step 2: Smoke-test the readme section on claude-pal**

Run `/oss-health readme` on claude-pal. Expected: `✓ README exists`, `✓ has description`, `✓ has install/usage`, `✗ license badge`, `✗ CI badge` (no workflow yet), `✓ contributing section`, `✓ license section`, `⚠ disclaimer` (mentions Anthropic/Claude without disclaimer check).

- [ ] **Step 3: Commit**

```bash
cd ~/.claude && git add skills/oss-health/SKILL.md && git commit -m "feat(skill): add oss-health readme section"
```

---

## Task 4: Implement `github` section

**Files:**
- Modify: `~/.claude/skills/oss-health/SKILL.md` — append Section: github

- [ ] **Step 1: Append the `github` section to SKILL.md**

Append the following to `~/.claude/skills/oss-health/SKILL.md`:

````markdown

---

## Section: github

Check the `.github/` directory structure. Use Glob to check for files.

### Tier 1 — Essential

**CI workflow**
- Check: any `.github/workflows/*.yml` or `.github/workflows/*.yaml` file exists
- If none found: `✗ .github/workflows/ — no CI workflow [Tier 1]`
  - Fix: Detect STACK and write `.github/workflows/ci.yml` with the appropriate template:

  **Shell/bats** (detected: `.sh` files exist or `tests/*.bats` files exist):
  ```yaml
  name: CI
  on:
    push:
      branches: [main]
    pull_request:
  jobs:
    shellcheck:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: ShellCheck
          run: shellcheck $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*')
    test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
          with:
            submodules: recursive
        - name: Run BATS tests
          run: bats tests/
  ```

  **Node** (package.json present):
  ```yaml
  name: CI
  on:
    push:
      branches: [main]
    pull_request:
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: actions/setup-node@v4
          with:
            node-version: '20'
            cache: 'npm'
        - run: npm ci
        - run: npm test
  ```

  **Python** (pyproject.toml or requirements.txt present):
  ```yaml
  name: CI
  on:
    push:
      branches: [main]
    pull_request:
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: actions/setup-python@v5
          with:
            python-version: '3.x'
        - run: pip install -e ".[dev]"
        - run: pytest
  ```

  **Generic** (no stack detected):
  ```yaml
  name: CI
  on:
    push:
      branches: [main]
    pull_request:
  jobs:
    build:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: Build and test
          run: echo "TODO: add your build and test steps here"
  ```

- If found: `✓ .github/workflows/ (found: <filenames>)`

**PR template**
- Check: `.github/pull_request_template.md` or `.github/PULL_REQUEST_TEMPLATE.md` exists
- If missing: `✗ .github/pull_request_template.md — no PR template [Tier 1]`
  - Fix: Write `.github/pull_request_template.md`:
    ```markdown
    ## Summary
    <!-- What does this PR do and why? -->

    ## Changes
    <!-- Key changes made -->

    ## Testing
    - [ ] Tests pass locally
    - [ ] Linting passes
    - [ ] Manually verified the change works as expected

    ## Related Issues
    <!-- Closes #N -->
    ```
- If present: `✓ PR template`

### Tier 2 — Important

**Bug report issue template**
- Check: `.github/ISSUE_TEMPLATE/bug_report.yml` or `.github/ISSUE_TEMPLATE/bug_report.md` exists
- If missing: `✗ .github/ISSUE_TEMPLATE/bug_report.yml — no bug report template [Tier 2]`
  - Fix: Write `.github/ISSUE_TEMPLATE/bug_report.yml`:
    ```yaml
    name: Bug Report
    description: File a bug report
    title: "[Bug]: "
    labels: ["bug"]
    body:
      - type: markdown
        attributes:
          value: "Thanks for taking the time to fill out this bug report!"
      - type: textarea
        id: what-happened
        attributes:
          label: What happened?
          description: Describe the bug and what you expected to happen.
        validations:
          required: true
      - type: textarea
        id: reproduce
        attributes:
          label: Steps to reproduce
          placeholder: "1. ...\n2. ...\n3. ..."
        validations:
          required: true
      - type: textarea
        id: environment
        attributes:
          label: Environment
          placeholder: "OS, version, relevant config..."
    ```
- If present: `✓ Bug report template`

**Feature request issue template**
- Check: `.github/ISSUE_TEMPLATE/feature_request.yml` or `.github/ISSUE_TEMPLATE/feature_request.md` exists
- If missing: `✗ .github/ISSUE_TEMPLATE/feature_request.yml — no feature request template [Tier 2]`
  - Fix: Write `.github/ISSUE_TEMPLATE/feature_request.yml`:
    ```yaml
    name: Feature Request
    description: Suggest an idea or enhancement
    title: "[Feature]: "
    labels: ["enhancement"]
    body:
      - type: textarea
        id: problem
        attributes:
          label: Is your feature request related to a problem?
          placeholder: "I'm always frustrated when..."
      - type: textarea
        id: solution
        attributes:
          label: Describe the solution you'd like
        validations:
          required: true
      - type: textarea
        id: alternatives
        attributes:
          label: Alternatives considered
    ```
- If present: `✓ Feature request template`

**CODEOWNERS**
- Check: `.github/CODEOWNERS` exists
- If missing: `✗ .github/CODEOWNERS — no code ownership defined [Tier 2]`
  - Fix: Detect `GITHUB_USERNAME` from remote URL (extract owner from `git remote get-url origin`). Write `.github/CODEOWNERS`:
    ```
    # Global owner — all files
    * @GITHUB_USERNAME
    ```
- If present: `✓ CODEOWNERS`

**dependabot.yml**
- Check: `.github/dependabot.yml` exists
- If missing: `✗ .github/dependabot.yml — no automated dependency updates [Tier 2]`
  - Fix: Write `.github/dependabot.yml`. Always include `github-actions`. Add package ecosystem if stack detected:
    - Base (all stacks):
      ```yaml
      version: 2
      updates:
        - package-ecosystem: "github-actions"
          directory: "/"
          schedule:
            interval: "weekly"
      ```
    - Node: append a second entry with `package-ecosystem: "npm"`, same directory and schedule
    - Python: append with `package-ecosystem: "pip"`
    - Rust: append with `package-ecosystem: "cargo"`
- If present: `✓ dependabot.yml`

### Tier 3 — Polish

**FUNDING.yml**
- Check: `.github/FUNDING.yml` exists
- If missing: `✗ .github/FUNDING.yml — no sponsor config [Tier 3]`
  - Fix: Write `.github/FUNDING.yml`:
    ```yaml
    github: [GITHUB_USERNAME]
    ```
  - Then print the manual guidance block for GitHub Sponsors (see Manual Guidance section).
- If present: `✓ FUNDING.yml`

**stale.yml**
- Check: `.github/workflows/stale.yml` exists, or any workflow contains `actions/stale`
- If missing: `✗ Stale issue/PR management not configured [Tier 3]`
  - Fix: Write `.github/workflows/stale.yml`:
    ```yaml
    name: Mark stale issues and pull requests
    on:
      schedule:
        - cron: '30 1 * * *'
    jobs:
      stale:
        runs-on: ubuntu-latest
        permissions:
          issues: write
          pull-requests: write
        steps:
          - uses: actions/stale@v9
            with:
              stale-issue-message: 'This issue has been inactive for 60 days and will be closed in 7 days if there is no further activity.'
              stale-pr-message: 'This PR has been inactive for 60 days and will be closed in 7 days if there is no further activity.'
              days-before-stale: 60
              days-before-close: 7
    ```
- If present: `✓ Stale management configured`
````

- [ ] **Step 2: Smoke-test the github section on claude-pal**

Run `/oss-health github` on claude-pal. Expected: `✗ CI workflow`, `✗ PR template`, `✗ bug report template`, `✗ feature request template`, `✗ CODEOWNERS`, `✗ dependabot.yml`, `✗ FUNDING.yml`, `✗ stale.yml`.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude && git add skills/oss-health/SKILL.md && git commit -m "feat(skill): add oss-health github section"
```

---

## Task 5: Implement `ci` section

**Files:**
- Modify: `~/.claude/skills/oss-health/SKILL.md` — append Section: ci

- [ ] **Step 1: Append the `ci` section to SKILL.md**

Append the following to `~/.claude/skills/oss-health/SKILL.md`:

````markdown

---

## Section: ci

Examine existing CI/CD workflow quality. Read all files under `.github/workflows/`.

If no workflow files exist: print `✗ No CI workflows found — run /oss-health github to scaffold one first` and stop this section.

For checks below, inspect all found workflow files collectively.

### Tier 1 — Essential

**Workflow runs on pull_request**
- Check: at least one workflow has `pull_request` in its `on:` trigger block
- If missing from all workflows: `✗ CI — no workflow triggers on pull_request [Tier 1]`
  - Fix: Add `pull_request:` to the `on:` block of the primary CI workflow (prefer `ci.yml`).
- If present: `✓ CI triggers on pull_request`

**Test suite executed**
- Check: any workflow step runs a recognizable test command: `bats`, `pytest`, `npm test`, `yarn test`, `cargo test`, `go test`, `jest`, `mocha`, `rspec`, `phpunit`
- If not found: `⚠ CI — no recognizable test execution step [Tier 1]`
  - Note: "Add a step that runs your test suite. For BATS: `run: bats tests/`. For pytest: `run: pytest`."
- If found: `✓ CI runs tests (detected: <command>)`

**Linting enforced**
- Check: any workflow step runs a linter: `shellcheck`, `eslint`, `flake8`, `ruff`, `pylint`, `clippy`, `golangci-lint`, `rubocop`
- If not found: `⚠ CI — no linting step detected [Tier 1]`
  - Note: "Add a lint step. For shell: `run: shellcheck $(find . -name '*.sh' -not -path '*/bats/*')`. For Node: `run: npm run lint`."
- If found: `✓ CI runs linting (detected: <tool>)`

### Tier 2 — Important

**Separate lint and test jobs**
- Check: CI has at least two distinct `jobs:` entries
- If all work is in a single job: `⚠ CI — lint and test in a single job [Tier 2]`
  - Note: "Splitting lint and test into separate jobs makes failures immediately distinguishable in the GitHub Actions UI."
- If multiple jobs: `✓ CI has separate jobs`

**Workflow badge wired to README**
- Check: README.md contains a badge URL referencing one of the workflow filenames
- If missing: `⚠ CI — workflow badge not in README [Tier 2]`
  - Note: "Run `/oss-health readme` to add the badge." (Fix is in the readme section to avoid double-writing.)
- If present: `✓ CI badge in README`

### Tier 3 — Polish

**Automated release workflow**
- Check: any workflow filename contains `release` or any workflow uses `actions/create-release`, `softprops/action-gh-release`, or `release-drafter/release-drafter`
- If absent: `✗ No automated release workflow [Tier 3]`
  - Note only: "Consider a release workflow triggered on `push: tags: ['v*']` using `softprops/action-gh-release` to publish GitHub Releases automatically."
- If present: `✓ Automated release workflow found`

**Security scanning**
- Check: any workflow uses `github/codeql-action`, `ossf/scorecard-action`, or `anchore/scan-action`
- If absent: `✗ No security scanning workflow [Tier 3]`
  - Note only: "Enable CodeQL via Settings → Security → Code scanning → Set up CodeQL. GitHub handles the workflow addition automatically."
- If present: `✓ Security scanning configured`
````

- [ ] **Step 2: Smoke-test the ci section on claude-pal**

Run `/oss-health ci` on claude-pal before any workflow is created. Expected: `✗ No CI workflows found — run /oss-health github to scaffold one first`.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude && git add skills/oss-health/SKILL.md && git commit -m "feat(skill): add oss-health ci section"
```

---

## Task 6: Implement `releases` section and manual guidance block

**Files:**
- Modify: `~/.claude/skills/oss-health/SKILL.md` — append Section: releases and Manual Guidance

- [ ] **Step 1: Append the `releases` section and manual guidance to SKILL.md**

Append the following to `~/.claude/skills/oss-health/SKILL.md`:

````markdown

---

## Section: releases

Check versioning and release discipline.

### Tier 1 — Essential

**Tag or release exists (or v0.x flagged)**
- Run `git tag --list` to see version tags. Also check README for "v0.", "early development", "pre-release", "alpha", or "beta".
- If no tags AND no pre-release language in README: `✗ releases — no version tags and no pre-release disclaimer [Tier 1]`
  - Note: "Create your first tag: `git tag v0.1.0 && git push origin v0.1.0`. Or add an early-development note to your README."
- If v0.x language present but no tags: `⚠ releases — pre-release noted in README but no tags yet [Tier 1]`
  - Note: "Consider tagging even pre-releases so users can pin to a known version: `git tag v0.1.0 && git push origin v0.1.0`"
- If tags exist: `✓ releases — version tags found (latest: <tag>)`

**CHANGELOG present and not empty**
- Check: `CHANGELOG.md` exists AND contains at least one version entry (a line matching `## [` beyond just `## [Unreleased]`)
- If missing: `✗ CHANGELOG — not present` (also reported in files section if applicable)
- If stub only (no version entries): `⚠ CHANGELOG — no release entries yet`
  - Note: "Add an entry for your first release using Keep a Changelog format: `## [0.1.0] - YYYY-MM-DD`"
- If has entries: `✓ CHANGELOG has release entries`

### Tier 2 — Important

**Follows semantic versioning**
- Check existing git tags. If any exist, verify they match `/^v?\d+\.\d+\.\d+/`
- If tags present but don't follow semver: `⚠ releases — tags don't follow semver (vMAJOR.MINOR.PATCH) [Tier 2]`
  - Note: "Semantic versioning: MAJOR for breaking changes, MINOR for new features, PATCH for bug fixes. See semver.org."
- If no tags: skip this check
- If tags follow semver: `✓ Semantic versioning followed`

**Follows Keep a Changelog format**
- Check `CHANGELOG.md` for `## [Unreleased]` and/or `## [X.Y.Z] - YYYY-MM-DD` sections
- Also check for links to keepachangelog.com and semver.org
- If format correct but links missing: `⚠ CHANGELOG — format looks right but missing footer links [Tier 2]`
  - Fix: Append footer to CHANGELOG.md:
    ```markdown

    [unreleased]: REPO_URL/compare/vLATEST_TAG...HEAD
    ```
    And add the standard keepachangelog.com attribution line in the header if not present.
- If not following format: `⚠ CHANGELOG — does not follow Keep a Changelog format [Tier 2]`
  - Note: "Restructure CHANGELOG to use `## [Unreleased]` and `## [X.Y.Z] - YYYY-MM-DD` sections. See https://keepachangelog.com"
- If format correct with links: `✓ Keep a Changelog format`

### Tier 3 — Polish

**Release notes auto-generated or release drafter configured**
- Check: any `.github/workflows/` file uses `release-drafter/release-drafter`, `softprops/action-gh-release`, or `changelogithub`
- If absent: `✗ No release automation [Tier 3]`
  - Note only: "Consider `release-drafter/release-drafter` (auto-drafts release notes from PR titles) or `softprops/action-gh-release` (publishes a GitHub Release when you push a tag)."
- If present: `✓ Release automation configured`

---

## Manual Guidance: UI/Admin Steps

When any of the following situations are encountered, print the corresponding numbered walkthrough. These steps require GitHub web UI access — never write files for these.

**Branch protection rules** (print when CI workflow was just created or already exists):
```
To protect your main branch:
1. Go to your repo on GitHub → Settings → Branches
2. Click "Add rule" (or edit existing rule for main/master)
3. Branch name pattern: main
4. Enable: "Require a pull request before merging"
5. Enable: "Require status checks to pass before merging"
   → Add your CI job names as required checks (e.g. "shellcheck", "test")
6. Enable: "Do not allow bypassing the above settings"
7. Click Save changes
```

**Repo topics/tags** (print at end of full run if not already done):
```
To add topics to your repo (improves discoverability):
1. Go to your repo on GitHub
2. Click the gear icon next to "About" (top-right of the repo page)
3. Add relevant topics (e.g. claude-code, automation, github-actions, open-source)
4. Click Save changes
```

**Secret scanning and Dependabot alerts** (print when dependabot.yml was just created):
```
To enable security features:
1. Go to your repo on GitHub → Settings → Security
2. Under "Vulnerability alerts": enable Dependabot alerts
3. Under "Code security and analysis":
   → Enable Secret scanning
   → Enable Push protection (prevents committing secrets)
```

**GitHub Sponsors** (print when FUNDING.yml was just created):
```
To activate GitHub Sponsors (FUNDING.yml has been created):
1. Go to github.com/sponsors and click "Get sponsored"
2. Complete the Sponsors profile (requires a Stripe account)
3. Once approved, a "Sponsor" button will appear on your repo automatically
```
````

- [ ] **Step 2: Smoke-test the releases section on claude-pal**

Run `/oss-health releases` on claude-pal. Expected: `⚠ pre-release noted in README but no tags yet` (README says "v0.x, Not yet usable"), `✓ CHANGELOG has release entries`, `⚠ tags don't follow semver` (no tags yet), `✓ Keep a Changelog format`.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude && git add skills/oss-health/SKILL.md && git commit -m "feat(skill): add oss-health releases section and manual guidance"
```

---

## Task 7: Full run validation on claude-pal

Validate the complete skill works end-to-end before applying fixes.

- [ ] **Step 1: Run full audit without fixing**

In a Claude Code session on the claude-pal repo, run:
```
/oss-health
```

When asked "Fix all auto-fixable gaps automatically?", answer **n**.

Verify the audit reports match the expected gaps (from the pre-audit):
- files: `✗ CONTRIBUTING.md`, `✗ CODE_OF_CONDUCT.md`, `✗ SECURITY.md`, `✓ LICENSE`, `✓ CHANGELOG.md`, `✓ .gitignore`
- readme: `✗ license badge`, `✗ CI badge`, `✓ description`, `✓ install/usage`, `✓ contributing section`, `✓ license section`
- github: all seven items `✗` (no `.github/` directory exists)
- ci: `✗ No CI workflows found`
- releases: `⚠ pre-release noted but no tags`, `✓ CHANGELOG has entries`

If any section reports unexpectedly, re-read that section in SKILL.md and adjust wording.

- [ ] **Step 2: Verify arg routing**

Run `/oss-health files` — confirm only the files section runs.
Run `/oss-health badarg` — confirm the error message prints and stops.

---

## Task 8: Apply the skill to claude-pal — auto-fixable items

- [ ] **Step 1: Run the skill and accept all auto-fixes**

In a Claude Code session on the claude-pal repo, run:
```
/oss-health
```

When asked "Fix all auto-fixable gaps automatically?", answer **y**.

The skill should create the following files in the claude-pal repo:
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `SECURITY.md`
- `.github/workflows/ci.yml` (shell/bats stack)
- `.github/pull_request_template.md`
- `.github/ISSUE_TEMPLATE/bug_report.yml`
- `.github/ISSUE_TEMPLATE/feature_request.yml`
- `.github/CODEOWNERS`
- `.github/dependabot.yml`
- `.github/FUNDING.yml`
- `.github/workflows/stale.yml`
- README.md updated: license badge and CI badge added

- [ ] **Step 2: Review each generated file**

Read each created file and verify:
- CONTRIBUTING.md references BATS and shellcheck (shell/bats stack detected)
- CODE_OF_CONDUCT.md has the contact email filled in (not placeholder)
- SECURITY.md references the correct GitHub advisory URL for jnurre64/claude-pal
- `ci.yml` has `shellcheck` and `bats tests/` steps, triggers on `pull_request`
- CODEOWNERS has `* @jnurre64`
- README badges are at the top and link to correct URLs

Fix any issues manually before committing.

- [ ] **Step 3: Commit all generated files to claude-pal**

```bash
git add CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .github/
git add README.md
git commit -m "chore: apply oss-health skill — add community health files and .github/ structure"
```

---

## Task 9: Apply the skill to claude-pal — manual walkthrough items

- [ ] **Step 1: Follow the branch protection walkthrough**

The skill will have printed the branch protection steps. Follow them:
1. GitHub → jnurre64/claude-pal → Settings → Branches → Add rule
2. Pattern: `main`
3. Enable: Require PR before merging, Require status checks (add `shellcheck` and `test` job names), Do not allow bypassing

- [ ] **Step 2: Follow the repo topics walkthrough**

1. GitHub → jnurre64/claude-pal → gear icon next to About
2. Add topics: `claude-code`, `automation`, `docker`, `github-agent`, `plugin`

- [ ] **Step 3: Follow the secret scanning walkthrough**

1. GitHub → jnurre64/claude-pal → Settings → Security
2. Enable Dependabot alerts, Secret scanning, Push protection

- [ ] **Step 4: Run /oss-health one more time to confirm clean**

Run `/oss-health` again. Expected: all Tier 1 items `✓`, most Tier 2 items `✓`, Tier 3 gaps noted but not blocking.

- [ ] **Step 5: Final commit if any remaining fixes were made**

```bash
git add -p  # review and stage any remaining changes
git commit -m "chore: apply oss-health skill — remaining fixes after manual steps"
```
