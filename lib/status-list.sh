# lib/status-list.sh
# shellcheck shell=bash
# List runs and reconcile against docker ps.

pal_list_runs() {
    local runs_dir
    runs_dir=$(pal_runs_dir)
    [ ! -d "$runs_dir" ] && { echo "No runs yet."; return 0; }

    printf '%-32s %-10s %-32s %-10s\n' "RUN_ID" "STATE" "REPO#NUMBER" "OUTCOME"
    printf '%-32s %-10s %-32s %-10s\n' "--------------------------------" "----------" "--------------------------------" "----------"

    for rd in "$runs_dir"/*/; do
        [ ! -d "$rd" ] && continue
        local run_id
        run_id=$(basename "$rd")
        local meta="$rd/launch_meta.json"
        local status="$rd/status.json"
        local cid_file="$rd/container_id"

        local repo number
        if [ -f "$meta" ]; then
            repo=$(jq -r .repo "$meta")
            number=$(jq -r '.issue_number // .pr_number' "$meta")
        else
            repo="?"; number="?"
        fi

        local state outcome
        if [ -f "$status" ]; then
            state="complete"
            outcome=$(jq -r .outcome "$status")
        elif [ -f "$cid_file" ]; then
            local cid
            cid=$(cat "$cid_file")
            if docker ps --filter "id=$cid" --format '{{.ID}}' 2>/dev/null | grep -q .; then
                state="running"
                outcome="-"
            else
                # Container gone but no status.json — reconcile as stale
                state="stale"
                outcome="unknown"
            fi
        else
            state="abandoned"
            outcome="-"
        fi

        printf '%-32s %-10s %-32s %-10s\n' "$run_id" "$state" "${repo}#${number}" "$outcome"
    done
}

pal_show_run() {
    local run_id="$1"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    [ ! -d "$run_dir" ] && { echo "pal: no such run: $run_id" >&2; return 1; }

    echo "=== Launch metadata ==="
    [ -f "$run_dir/launch_meta.json" ] && jq . "$run_dir/launch_meta.json"
    echo ""
    echo "=== Status ==="
    if [ -f "$run_dir/status.json" ]; then
        jq . "$run_dir/status.json"
    else
        echo "(no status.json yet — run may be in flight)"
    fi
    echo ""
    echo "Log: $run_dir/log"
}

pal_clean_runs() {
    local runs_dir
    runs_dir=$(pal_runs_dir)
    [ ! -d "$runs_dir" ] && return 0

    local cutoff_days="${1:-30}"
    local removed=0
    for rd in "$runs_dir"/*/; do
        [ ! -d "$rd" ] && continue
        if [ "$(find "$rd" -maxdepth 0 -mtime +"$cutoff_days" -print)" ]; then
            rm -rf "$rd"
            removed=$((removed+1))
        fi
    done
    echo "Removed $removed runs older than $cutoff_days days."
}
