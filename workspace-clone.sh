#!/usr/bin/env bash
# workspace-clone.sh — Manage all repos listed in workspace.toml.
#
# Usage:
#   ./workspace-clone.sh [OPTIONS]
#
# Options:
#   --dest DIR        Root directory for cloning (default: workspace root)
#   --fetch           Fetch from origin in every already-cloned repo
#   --pull            Pull (fetch + fast-forward) in every already-cloned repo
#   --checkout BRANCH Checkout BRANCH in every already-cloned repo
#   --help
#
# Examples:
#   # Clone any repos not yet present:
#   ./workspace-clone.sh
#
#   # Clone missing repos, then fetch + switch everything to develop:
#   ./workspace-clone.sh --fetch --checkout develop
#
#   # Pull latest changes in all repos (fast-forward only):
#   ./workspace-clone.sh --pull
#
#   # Fetch all repos without switching branches:
#   ./workspace-clone.sh --fetch
#
#   # Switch all repos to main:
#   ./workspace-clone.sh --checkout main

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$SCRIPT_DIR/workspace.toml"
DEST="$WORKSPACE_ROOT"
DO_FETCH=false
DO_PULL=false
CHECKOUT_BRANCH=""

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)     DEST="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
        --fetch)    DO_FETCH=true; shift ;;
        --pull)     DO_PULL=true; shift ;;
        --checkout) CHECKOUT_BRANCH="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: workspace.toml not found at $MANIFEST" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Parse workspace.toml — extract (path, remote) pairs from [[repo]] blocks.
# -----------------------------------------------------------------------------
mapfile -t REPO_PAIRS < <(awk '
    /^\[\[repo\]\]/ {
        if (path != "" && remote != "") print path " " remote
        path=""; remote=""
    }
    /^path /   { gsub(/.*= *"/, ""); gsub(/".*/, ""); path=$0 }
    /^remote / { gsub(/.*= *"/, ""); gsub(/".*/, ""); remote=$0 }
    END { if (path != "" && remote != "") print path " " remote }
' "$MANIFEST")

# -----------------------------------------------------------------------------
# Process each repo
# -----------------------------------------------------------------------------
CLONED=0
SKIPPED=0
FETCHED=0
PULLED=0
SWITCHED=0
FAILED=0

for pair in "${REPO_PAIRS[@]}"; do
    rel="${pair%% *}"
    remote="${pair#* }"
    dst="$DEST/$rel"

    # ── Clone if missing ──────────────────────────────────────────────────────
    if [[ ! -d "$dst/.git" ]]; then
        mkdir -p "$(dirname "$dst")"
        echo "[clone]    $rel"
        echo "           $remote → $dst"
        if git clone -b develop "$remote" "$dst"; then
            CLONED=$((CLONED + 1))
        else
            echo "[fail]     $rel" >&2
            FAILED=$((FAILED + 1))
            continue
        fi
    else
        echo "[present]  $rel"
        SKIPPED=$((SKIPPED + 1))
    fi

    # ── Fetch ─────────────────────────────────────────────────────────────────
    if [[ "$DO_FETCH" == true ]]; then
        if git -C "$dst" fetch --quiet --prune origin 2>/dev/null; then
            echo "           fetched"
            FETCHED=$((FETCHED + 1))
        else
            echo "           fetch failed (skipping)" >&2
        fi
    fi

    # ── Pull (fetch + fast-forward merge) ────────────────────────────────────
    if [[ "$DO_PULL" == true ]]; then
        branch=$(git -C "$dst" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if git -C "$dst" pull --ff-only --quiet origin "$branch" 2>/dev/null; then
            echo "           pulled $branch"
            PULLED=$((PULLED + 1))
        else
            echo "           pull failed on $branch (diverged or dirty?)" >&2
            FAILED=$((FAILED + 1))
        fi
    fi

    # ── Checkout branch ───────────────────────────────────────────────────────
    if [[ -n "$CHECKOUT_BRANCH" ]]; then
        current=$(git -C "$dst" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

        if [[ "$current" == "$CHECKOUT_BRANCH" ]]; then
            echo "           already on $CHECKOUT_BRANCH"
        elif git -C "$dst" show-ref --verify --quiet "refs/heads/$CHECKOUT_BRANCH"; then
            # Branch exists locally
            if git -C "$dst" checkout --quiet "$CHECKOUT_BRANCH"; then
                echo "           switched to $CHECKOUT_BRANCH  (was: $current)"
                SWITCHED=$((SWITCHED + 1))
            else
                echo "           checkout failed  (dirty working tree?)" >&2
                FAILED=$((FAILED + 1))
            fi
        elif git -C "$dst" show-ref --verify --quiet "refs/remotes/origin/$CHECKOUT_BRANCH"; then
            # Branch exists on remote — create local tracking branch
            if git -C "$dst" checkout --quiet -b "$CHECKOUT_BRANCH" --track "origin/$CHECKOUT_BRANCH"; then
                echo "           switched to $CHECKOUT_BRANCH  (tracking origin, was: $current)"
                SWITCHED=$((SWITCHED + 1))
            else
                echo "           checkout failed" >&2
                FAILED=$((FAILED + 1))
            fi
        else
            echo "           branch '$CHECKOUT_BRANCH' not found locally or on origin" >&2
            FAILED=$((FAILED + 1))
        fi
    fi
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "Summary:"
echo "  cloned=$CLONED  present=$SKIPPED  fetched=$FETCHED  pulled=$PULLED  switched=$SWITCHED  failed=$FAILED"
echo "  root: $DEST"
