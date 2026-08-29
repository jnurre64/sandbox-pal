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
