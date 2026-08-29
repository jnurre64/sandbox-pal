# lib/memory-proposals.sh
# shellcheck shell=bash
# Triage memory proposals written by pipeline phases. run-pipeline.sh copies
# <worktree>/.agent-data/memory-proposals/*.md to <runs>/<run-id>/memory-proposals/
# (bind-mounted /status). Nothing reaches ~/.claude/projects/<slug>/memory/
# unless a human adopts it here. Triaged files move to memory-proposals/.triaged/.

# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/memory-sync.sh"

# _pal_proposal_field <file> <key> — scalar frontmatter value (first match).
_pal_proposal_field() {
    local file="$1" key="$2"
    awk -v key="$key" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        NR > 1 && index($0, key ":") == 1 {
            sub("^" key ":[[:space:]]*", ""); print; exit
        }
    ' "$file"
}

# pal_memory_proposals_list [run-id]
pal_memory_proposals_list() {
    local only_run="${1:-}"
    local runs_dir run_dir run_id f name desc found=0
    runs_dir="$(pal_runs_dir)"
    [ -d "$runs_dir" ] || { echo "pal: no pending memory proposals" >&2; return 0; }
    for run_dir in "$runs_dir"/*/; do
        run_dir="${run_dir%/}"
        run_id="$(basename "$run_dir")"
        [ -n "$only_run" ] && [ "$run_id" != "$only_run" ] && continue
        [ -d "$run_dir/memory-proposals" ] || continue
        for f in "$run_dir"/memory-proposals/*.md; do
            [ -f "$f" ] || continue
            name="$(_pal_proposal_field "$f" name)"
            desc="$(_pal_proposal_field "$f" description)"
            printf '%s\t%s\t%s — %s\n' "$run_id" "$(basename "$f")" "${name:-?}" "${desc:-}"
            found=1
        done
    done
    [ "$found" -eq 1 ] || echo "pal: no pending memory proposals${only_run:+ for run $only_run}" >&2
    return 0
}

_pal_proposal_path() { # <run-id> <file> → path, or 1 if missing
    local p
    p="$(pal_run_dir "$1")/memory-proposals/$2"
    if [ ! -f "$p" ]; then
        echo "pal: no such proposal: $1/$2" >&2
        return 1
    fi
    printf '%s\n' "$p"
}

_pal_proposal_triage() { # <proposal-path>
    local dir
    dir="$(dirname "$1")/.triaged"
    mkdir -p "$dir"
    mv "$1" "$dir/"
}

# pal_memory_proposal_adopt <run-id> <file> <host-repo-path>
pal_memory_proposal_adopt() {
    local run_id="$1" file="$2" host_repo="$3"
    local src name desc slug mem_dir dest
    src="$(_pal_proposal_path "$run_id" "$file")" || return 1

    name="$(_pal_proposal_field "$src" name)"
    if [ -z "$name" ]; then
        echo "pal: $file has no 'name:' in its frontmatter — fix it or --discard" >&2
        return 1
    fi
    if [ "$name" != "${file%.md}" ]; then
        echo "pal: name '$name' does not match filename '$file' (expected ${name}.md)" >&2
        return 1
    fi
    desc="$(_pal_proposal_field "$src" description)"

    slug="$(pal_memory_slug "$host_repo")"
    mem_dir="${HOME}/.claude/projects/${slug}/memory"
    dest="$mem_dir/$file"
    if [ -e "$dest" ]; then
        echo "pal: $dest already exists — not overwriting. Diff (existing → proposal):" >&2
        diff -u "$dest" "$src" >&2 || true
        return 1
    fi

    mkdir -p "$mem_dir"
    cp "$src" "$dest"
    if [ ! -f "$mem_dir/MEMORY.md" ]; then
        printf '# Memory Index\n\n' > "$mem_dir/MEMORY.md"
    fi
    printf -- '- [%s](%s) — %s\n' "$name" "$file" "$desc" >> "$mem_dir/MEMORY.md"
    _pal_proposal_triage "$src"
    echo "pal: adopted $file → $dest (index line appended to MEMORY.md)"
}

# pal_memory_proposal_discard <run-id> <file>
pal_memory_proposal_discard() {
    local src
    src="$(_pal_proposal_path "$1" "$2")" || return 1
    _pal_proposal_triage "$src"
    echo "pal: discarded $2 (moved to .triaged/)"
}
