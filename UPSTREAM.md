# Upstream Vendored Files

This project vendors pieces of `jnurre64/claude-agent-dispatch`. Each file here is tracked with its source path, the upstream commit at time of vendor, and any local modifications.

Resync via `scripts/diff-upstream.sh` (see Phase 8).

## Prompts

| Local path | Source | Upstream SHA | Modifications |
|---|---|---|---|
| `image/opt/pal/prompts/adversarial-plan.md` | `prompts/adversarial-plan.md` | 07b9347774702e66064abe62d6d329f48b459121 | none |
| `image/opt/pal/prompts/post-impl-review.md` | `prompts/post-impl-review.md` | 07b9347774702e66064abe62d6d329f48b459121 | none |
| `image/opt/pal/prompts/post-impl-retry.md` | `prompts/post-impl-retry.md` | 07b9347774702e66064abe62d6d329f48b459121 | none |
| `image/opt/pal/prompts/implement.md` | `prompts/implement.md` | 07b9347774702e66064abe62d6d329f48b459121 | removed label-state-machine references; updated intro to mention sandbox-pal container |

## Libraries

| Local path | Source | Upstream SHA | Modifications |
|---|---|---|---|
| `image/opt/pal/lib/review-gates.sh` | `scripts/lib/review-gates.sh` | 07b9347774702e66064abe62d6d329f48b459121 | replaced `set_label` calls with STATUS_* variable writes; kept gh issue comment calls |

## Conceptual patterns (not directly copied)

- Data-fetch pattern for gists and attachments (see `scripts/lib/data-fetch.sh` upstream) — reimplemented inline in our entrypoint with the same fetch-on-start, bind-to-env-var shape
- `_extract_review_json` helper — included in review-gates.sh above
