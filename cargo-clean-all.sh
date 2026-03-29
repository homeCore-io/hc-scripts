#!/usr/bin/env bash
# cargo-clean-all.sh — Run cargo clean for every Rust repo in workspace.toml.
#
# Usage:
#   ./scripts/cargo-clean-all.sh [--release] [--dry-run] [--manifest /path/to/workspace.toml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$WORKSPACE_ROOT/workspace.toml"
CARGO_ARGS=()
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            CARGO_ARGS+=("--release")
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --manifest)
            MANIFEST="$2"
            shift 2
            ;;
        --help|-h)
            sed -n '2,6p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: workspace.toml not found at $MANIFEST" >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is not installed or not in PATH" >&2
    exit 1
fi

# Parse [[repo]] blocks and collect each path value.
mapfile -t REPO_PATHS < <(awk '
    /^\[\[repo\]\]/ {
        if (path != "") print path
        path=""
    }
    /^path / {
        gsub(/.*= *"/, "")
        gsub(/".*/, "")
        path=$0
    }
    END {
        if (path != "") print path
    }
' "$MANIFEST")

if [[ ${#REPO_PATHS[@]} -eq 0 ]]; then
    echo "No repos found in manifest: $MANIFEST"
    exit 0
fi

TOTAL=0
CLEANED=0
SKIPPED=0
FAILED=0

for rel in "${REPO_PATHS[@]}"; do
    repo="$WORKSPACE_ROOT/$rel"

    if [[ ! -d "$repo" ]]; then
        echo "[skip]  $rel  (directory missing)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    manifest_path="$repo/Cargo.toml"
    if [[ ! -f "$manifest_path" ]]; then
        echo "[skip]  $rel  (no Cargo.toml)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    TOTAL=$((TOTAL + 1))
    cmd=(cargo clean --manifest-path "$manifest_path" "${CARGO_ARGS[@]}")

    echo "[clean] $rel"
    if $DRY_RUN; then
        printf '        %q ' "${cmd[@]}"
        printf '\n'
        CLEANED=$((CLEANED + 1))
        continue
    fi

    if "${cmd[@]}"; then
        CLEANED=$((CLEANED + 1))
    else
        echo "[fail]  $rel" >&2
        FAILED=$((FAILED + 1))
    fi

done

echo
echo "Summary: rust_repos=$TOTAL cleaned=$CLEANED skipped=$SKIPPED failed=$FAILED"
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
