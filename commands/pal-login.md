---
description: Use when the user wants to mint Claude credentials inside the sandbox-pal workspace container. Runs the interactive `claude /login` flow inside the container; credentials persist in the named volume `sandbox-pal-claude` until `/pal-logout`. Use when user says "log in to pal", "mint pal credentials", "authenticate the pal workspace", or similar.
---

# /sandbox-pal:pal-login

Mint Claude credentials inside the workspace container.

This opens an interactive `claude /login` flow (browser dance). Run once per
workspace lifetime; credentials persist in the Docker-managed named volume
`sandbox-pal-claude` until you run `/pal-logout` or delete the volume.

Invoke the `pal-login` skill.
