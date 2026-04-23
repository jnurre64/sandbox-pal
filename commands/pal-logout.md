---
description: Use when the user wants to remove Claude credentials from the sandbox-pal workspace container. Deletes the `.credentials.json` file inside the container; the named volume itself is preserved so the workspace can be re-authenticated with `/pal-login`. Use when user says "log out of pal", "clear pal credentials", "reset pal auth", or similar.
---

# /sandbox-pal:pal-logout

Delete Claude credentials from the workspace container.

This removes `/home/agent/.claude/.credentials.json` inside the workspace.
The named volume `sandbox-pal-claude` is preserved; run `/pal-login` to mint
fresh credentials.

Invoke the `pal-logout` skill.
