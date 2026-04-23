---
description: Use when the user hasn't configured sandbox-pal yet and wants a guided setup. Walks them through obtaining a fine-grained GitHub PAT and exporting `GH_TOKEN`, then pulling/starting the long-running workspace container and minting Claude credentials inside it via `/pal-login` (persisted in the `sandbox-pal-claude` named volume, never on the host). Use when user sees "missing required environment variable" from sandbox-pal, or asks "how do I set up pal", "configure sandbox-pal", "set pal tokens", or similar.
---

# /sandbox-pal:pal-setup

Guided, one-time setup for sandbox-pal.

Walk the user through:

1. Verify `docker` is on PATH and reachable (`docker info` succeeds).
2. Verify `GH_TOKEN` (or `GITHUB_TOKEN`) is exported in the shell. If missing,
   instruct:

       echo 'export GH_TOKEN=github_pat_<token>' >> ~/.bashrc
       source ~/.bashrc

   The PAT needs `Contents`, `Pull requests`, `Issues` (read/write) on target repos.
3. Ensure the `sandbox-pal:latest` image is present. Source the helper and call
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
   interactive browser flow). Credentials persist in the `sandbox-pal-claude`
   named volume; they never touch the host filesystem.
6. (Optional) `/pal-workspace edit-rules` — opens an empty
   `~/.config/sandbox-pal/container-CLAUDE.md` that will be synced into the
   container on every run. Use it for container-scoped behavior rules.
7. (Optional) create `~/.config/sandbox-pal/config.env` with non-secret knobs:

       PAL_CPUS=2.0
       PAL_MEMORY=4g
       PAL_SYNC_MEMORIES=true
       PAL_SYNC_TRANSCRIPTS=false

Report back what was verified and what still needs doing.
