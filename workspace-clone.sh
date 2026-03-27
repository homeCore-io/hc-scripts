#!/usr/bin/env bash
# workspace-clone.sh — Clone all repos listed in workspace.toml into their declared paths.
#
# Usage:
#   ./scripts/workspace-clone.sh [--dest /path/to/root]
#
# By default clones relative to the workspace root (parent of this script).
# Pass --dest to clone into a different root (e.g. a fresh machine setup).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$WORKSPACE_ROOT/workspace.toml"
DEST="$WORKSPACE_ROOT"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) DEST="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
        --help|-h)
            sed -n '2,6p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: workspace.toml not found at $MANIFEST" >&2
    exit 1
fi

# Parse workspace.toml: extract (path, remote) pairs from [[repo]] blocks.
# Each block has consecutive key=value lines; awk collects them and prints
# "path remote" when a new block starts or at EOF.
mapfile -t REPO_PAIRS < <(awk '
    /^\[\[repo\]\]/ {
        if (path != "" && remote != "") print path " " remote
        path=""; remote=""
    }
    /^path / { gsub(/.*= *"/, ""); gsub(/".*/, ""); path=$0 }
    /^remote / { gsub(/.*= *"/, ""); gsub(/".*/, ""); remote=$0 }
    END { if (path != "" && remote != "") print path " " remote }
' "$MANIFEST")

CLONED=0
SKIPPED=0
FAILED=0

for pair in "${REPO_PAIRS[@]}"; do
    rel="${pair%% *}"
    remote="${pair#* }"
    dst="$DEST/$rel"

    if [[ -d "$dst/.git" ]]; then
        echo "[skip]  $rel  (already cloned)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    mkdir -p "$(dirname "$dst")"
    echo "[clone] $rel"
    echo "        $remote → $dst"
    if git clone "$remote" "$dst"; then
        CLONED=$((CLONED + 1))
    else
        echo "[fail]  $rel" >&2
        FAILED=$((FAILED + 1))
    fi
done

echo
echo "Summary: cloned=$CLONED skipped=$SKIPPED failed=$FAILED"
echo "Root: $DEST"
