---
description: Use when the user hasn't configured claude-pal yet and wants a guided setup. Walks them through obtaining a fine-grained GitHub PAT and exporting `GH_TOKEN`, then pulling/starting the long-running workspace container and minting Claude credentials inside it via `/pal-login` (persisted in the `claude-pal-claude` named volume, never on the host). Use when user sees "missing required environment variable" from claude-pal, or asks "how do I set up pal", "configure claude-pal", "set pal tokens", or similar.
---

# /claude-pal:pal-setup

Guided, one-time setup for claude-pal.

Walk the user through:

1. Verify `docker` is on PATH and reachable.
2. Verify `GH_TOKEN` (or `GITHUB_TOKEN`) is exported in the shell. If missing,
   instruct:
       echo 'export GH_TOKEN=github_pat_<token>' >> ~/.bashrc
       source ~/.bashrc
   The PAT needs `Contents`, `Pull requests`, `Issues` (read/write) on target repos.
3. `docker pull claude-pal:latest`  (or build locally from `image/`).
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
