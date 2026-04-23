---
description: Use when the user wants to go from an idea to a pull request with pal — orchestrates the full flow (brainstorm → plan → publish → dispatch). Use when user says "plan an issue for pal", "have pal build this", "help me get pal to work on a feature", "brainstorm something for pal to implement", or similar. Depends on the superpowers plugin for the brainstorm and plan-writing steps.
---

# pal-brainstorm

Guide the user from an idea to a dispatched pal run that opens a PR.

**User's seed idea (may be empty):** $ARGUMENTS

## Prerequisite check

This flow depends on the `superpowers` plugin (provides `brainstorming` and `writing-plans` skills). If those skills are not listed in your current session's available skills, stop and tell the user:

> The /sandbox-pal:pal-brainstorm flow uses skills from the `superpowers` plugin. Install it from the `claude-plugins-official` marketplace, then run /sandbox-pal:pal-brainstorm again.

Do not attempt to proceed past this check if `superpowers:brainstorming` or `superpowers:writing-plans` are unavailable.

## Flow

1. **Brainstorm.** Invoke `superpowers:brainstorming` with the user's seed idea ($ARGUMENTS) to explore intent, requirements, and design. Let the brainstorming skill drive — don't short-circuit it.
2. **Write the plan.** Once the brainstorm converges, invoke `superpowers:writing-plans` to produce an implementation plan file under `docs/superpowers/plans/`.
3. **Checkpoint.** Show the user the plan file path and ask them to confirm before publishing to GitHub. If they want revisions, loop back to writing-plans.
4. **Publish.** Invoke the `pal-plan` skill (or `/sandbox-pal:pal-plan`) to post the plan as a GitHub issue comment. If the user hasn't named an existing issue, pal-plan will create a new one. Share the resulting issue URL with the user.
5. **Confirm.** Ask the user to review the posted plan on GitHub and confirm before dispatching. Offer to run /sandbox-pal:pal-implement in sync or async mode.
6. **Implement.** Invoke the `pal-implement` skill (or `/sandbox-pal:pal-implement <issue#>`) with `--async` if the user requested background execution. Otherwise run sync and stream the status to the user.

## Stopping points

Stop and ask the user between steps if:
- The brainstorm hasn't converged on concrete requirements.
- The generated plan looks too large or ambiguous to hand off to pal.
- The issue body needs manual edits on GitHub before dispatch.

Do not combine steps or skip the checkpoint before publishing — review is the point.
