# image/opt/pal/lib/worktree.sh
# shellcheck shell=bash
# Clone the target repo and create a worktree for this run.
# Uses GH_TOKEN for auth.

setup_worktree() {
    local repo="$1"       # owner/name
    local number="$2"     # issue or PR number
    local event_type="$3" # implement or revise

    local repo_cache="/home/agent/.cache/repos/$repo"
    local branch_name="agent/issue-${number}"

    # For revise, branch_name comes from the PR (filled in Task 6.1); for implement, we create it fresh
    mkdir -p "$(dirname "$repo_cache")"

    # Configure git to use gh as the credential helper so `git push` works over HTTPS.
    gh auth setup-git 2>/dev/null || log "worktree: warning, gh auth setup-git failed"

    if [ ! -d "$repo_cache/.git" ]; then
        log "worktree: cloning $repo to $repo_cache"
        GH_TOKEN="$GH_TOKEN" gh repo clone "$repo" "$repo_cache" -- --no-tags
    else
        log "worktree: fetching latest for $repo"
        (cd "$repo_cache" && git fetch --prune origin)
    fi

    # Create worktree on a fresh branch from origin/main (implement) or from PR branch (revise)
    if [ "$event_type" = "revise" ]; then
        local pr_branch
        pr_branch=$(GH_TOKEN="$GH_TOKEN" gh pr view "$number" --repo "$repo" --json headRefName --jq .headRefName)
        log "worktree: checking out PR branch $pr_branch"
        (cd "$repo_cache" && git fetch origin "$pr_branch":"$pr_branch" 2>/dev/null) || true
        git -C "$repo_cache" worktree add "$WORKTREE_DIR" "$pr_branch"
        BRANCH_NAME="$pr_branch"
    else
        log "worktree: creating worktree on $branch_name from origin/main"
        git -C "$repo_cache" worktree add -B "$branch_name" "$WORKTREE_DIR" origin/main
        BRANCH_NAME="$branch_name"
    fi

    # Configure git identity inside the worktree
    local bot_name="${AGENT_GIT_USER_NAME:-sandbox-pal}"
    local bot_email="${AGENT_GIT_USER_EMAIL:-sandbox-pal@local}"
    git -C "$WORKTREE_DIR" config user.name "$bot_name"
    git -C "$WORKTREE_DIR" config user.email "$bot_email"

    log "worktree: ready at $WORKTREE_DIR on branch $BRANCH_NAME"
}
