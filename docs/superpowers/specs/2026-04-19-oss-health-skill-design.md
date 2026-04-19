# oss-health Skill Design

**Date:** 2026-04-19
**Status:** Approved

## Overview

`oss-health` is a standalone global Claude Code skill (`~/.claude/skills/oss-health/SKILL.md`) that audits open source repository best practices, reports gaps by tier, and either scaffolds fixes inline or walks the user through manual UI steps. It is project-agnostic and reusable across any open source repository.

## Motivation

Derived from a comparative audit of `jnurre64/claude-pal-action` (strong open source hygiene baseline) and `jnurre64/claude-pal` (missing several standard GitHub community health files and CI/CD automation). The skill encodes the findings as a reusable checklist so any repo can be brought to the same standard.

## Architecture

### Skill location

```
~/.claude/skills/oss-health/
└── SKILL.md
```

Single file, no helpers or sub-files. Fully self-contained and portable.

### Invocation

```
/oss-health                 # full audit — all 5 categories in tier order
/oss-health files           # root community health files only
/oss-health readme          # README content quality only
/oss-health github          # .github/ directory only
/oss-health ci              # CI/CD workflows only
/oss-health releases        # versioning and release discipline only
```

### Arg routing

At startup the skill checks `args`. If empty it runs all sections sequentially. If a category name is passed it jumps to that section. Section headers in SKILL.md map 1:1 to valid arg values, so adding a new category later is just adding a new section block — no routing table to maintain.

### Context gathering

Before any checks, the skill reads existing repo files to gather context:
- Project name and description (from README, package.json, plugin.json, etc.)
- Primary language/stack (for CI scaffold selection)
- License type if present
- Contact email if findable

Generated files are pre-populated from this context rather than left as generic placeholders.

## Categories and Checklist Items

### `files` — Community health files at repo root

| Item | Tier |
|------|------|
| LICENSE | 1 — essential |
| CONTRIBUTING.md | 1 — essential |
| CODE_OF_CONDUCT.md | 1 — essential |
| SECURITY.md | 1 — essential |
| CHANGELOG.md | 2 — important |
| .gitignore | 2 — important |
| CITATION.cff | 3 — polish |
| MAINTAINERS / AUTHORS | 3 — polish |

### `readme` — README.md content quality

| Item | Tier |
|------|------|
| File exists | 1 — essential |
| Has project description | 1 — essential |
| Has install/usage section | 1 — essential |
| License badge | 2 — important |
| CI/test status badges | 2 — important |
| Contributing section or link | 2 — important |
| License section | 2 — important |
| Hero image or screenshot | 3 — polish |
| Disclaimer for community tools | 3 — polish |
| Link to full docs | 3 — polish |

### `github` — `.github/` directory

| Item | Tier |
|------|------|
| CI workflow (lint/test on PR) | 1 — essential |
| PR template | 1 — essential |
| Bug report issue template | 2 — important |
| Feature request issue template | 2 — important |
| CODEOWNERS | 2 — important |
| dependabot.yml | 2 — important |
| FUNDING.yml | 3 — polish |
| stale.yml | 3 — polish |

### `ci` — CI/CD automation quality (examines existing workflows)

| Item | Tier |
|------|------|
| Workflow runs on PR | 1 — essential |
| Test suite executed in CI | 1 — essential |
| Linting enforced in CI | 1 — essential |
| Separate lint and test jobs | 2 — important |
| Workflow badge wired to README | 2 — important |
| Automated release workflow | 3 — polish |
| Security scanning workflow | 3 — polish |

### `releases` — Versioning and release discipline

| Item | Tier |
|------|------|
| At least one tag/release exists (or v0.x explicitly flagged in README) | 1 — essential |
| CHANGELOG present and not empty | 1 — essential |
| Follows semantic versioning | 2 — important |
| Follows Keep a Changelog format | 2 — important |
| Release notes auto-generated or release drafter configured | 3 — polish |

## Fix Behavior

### Auto-scaffolded (skill creates the file)

| Gap | Action |
|-----|--------|
| CONTRIBUTING.md missing | Generate from repo context (name, stack, test command if detectable) |
| CODE_OF_CONDUCT.md missing | Contributor Covenant v2.1 boilerplate with contact email filled in |
| SECURITY.md missing | Template with private advisory instructions + supported versions stub |
| CITATION.cff missing | Generated from repo metadata |
| CI workflow missing | Scaffold for detected stack (shellcheck+bats, Node, Python, etc.) or generic |
| PR template missing | Standard template: Summary, Changes, Testing checklist, Related Issues |
| Issue templates missing | Bug report and feature request YAML templates |
| dependabot.yml missing | Weekly updates for GitHub Actions (and package manager if applicable) |
| CODEOWNERS missing | Single-maintainer stub using detected git author |
| FUNDING.yml missing | Scaffold with detected GitHub username; note that Sponsors requires UI activation |
| README badges missing | Insert CI status, license, and version badges at top of existing README |
| .gitignore missing common entries | Append standard patterns for detected stack |

### Guided walkthrough (UI/admin — numbered steps printed, nothing written)

- Branch protection rules (require PR reviews, require status checks, restrict force-push)
- Repo topics/tags (Settings → About → Topics)
- GitHub Sponsors enablement (FUNDING.yml scaffolded but Sponsors requires UI activation)
- Secret scanning and Dependabot alerts (Settings → Security)
- Default branch configuration
- Repository visibility (public/private)

### Fix prompt behavior

After reporting each gap the skill asks "Fix this now?" before writing anything. At the start of a full run the skill also offers "Fix all auto-fixable items?" to batch without per-item prompts.

## Skill Metadata

- **Name:** `oss-health`
- **Trigger description:** Covers "open source repo health", "missing contributing guidelines", "repo hygiene", "oss checklist", "open source best practices" — broad enough for natural language invocation without requiring exact command.

## Baseline Reference

The checklist items and templates are calibrated against the practices found in `jnurre64/claude-pal-action`, which serves as the reference implementation for this skill's "healthy" baseline. When generating scaffolded files, match the style and conventions of that repo unless the target repo has its own established conventions.

## Out of Scope

- Enforcing code style beyond what CI scaffolding covers
- Evaluating documentation content quality beyond structural checks
- Any changes to shared or production infrastructure
- Publishing to package registries or plugin marketplaces
