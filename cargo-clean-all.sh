#!/usr/bin/env bash
# cargo-clean-all.sh — Clean every Cargo target/ in the homeCore meta-layout.
#
# After the 2026-04 cargo restructure, Rust builds happen in four
# meta-workspaces, each with its own Cargo.toml + Cargo.lock + target/:
#
#   core/      plugins/      clients/      sdks/
#
# Per-repo target/ dirs (e.g. plugins/hc-yolink/target/) are orphans
# left over from pre-restructure or standalone CI clones — `cargo
# clean --manifest-path <per-repo>/Cargo.toml` resolves UP to the
# meta-workspace and silently misses them, so this script removes
# them directly.
#
# Usage:
#   ./cargo-clean-all.sh [--release] [--dry-run] [--keep-orphans]
#
# Flags:
#   --release        Clean only target/release/ (mirrors `cargo clean --release`).
#   --dry-run        Print what would happen, change nothing.
#   --keep-orphans   Skip the per-repo orphan target/ cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CARGO_ARGS=()
DRY_RUN=false
KEEP_ORPHANS=false
RELEASE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            CARGO_ARGS+=("--release")
            RELEASE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --keep-orphans)
            KEEP_ORPHANS=true
            shift
            ;;
        --help|-h)
            sed -n '2,22p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is not installed or not in PATH" >&2
    exit 1
fi

META_WORKSPACES=(core plugins clients sdks)

CLEANED=0
SKIPPED=0
FAILED=0
ORPHANS=0

# 1. Clean each meta-workspace once.
for ws in "${META_WORKSPACES[@]}"; do
    manifest="$WORKSPACE_ROOT/$ws/Cargo.toml"
    if [[ ! -f "$manifest" ]]; then
        echo "[skip]  $ws  (no Cargo.toml)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    cmd=(cargo clean --manifest-path "$manifest" "${CARGO_ARGS[@]}")
    echo "[clean] $ws"
    if $DRY_RUN; then
        printf '        %q ' "${cmd[@]}"; printf '\n'
        CLEANED=$((CLEANED + 1))
        continue
    fi

    if "${cmd[@]}"; then
        CLEANED=$((CLEANED + 1))
    else
        echo "[fail]  $ws" >&2
        FAILED=$((FAILED + 1))
    fi
done

# 2. Reap orphan per-repo target/ dirs under plugins/, clients/, sdks/.
#    (core/ has no per-crate orphans — its crates have always been
#    in a single workspace.) These dirs are unreachable from cargo
#    clean once a parent meta-workspace exists, so we prune them
#    directly. With --release we only prune target/release/ to
#    mirror cargo clean's semantics.
if ! $KEEP_ORPHANS; then
    for parent in plugins clients sdks; do
        while IFS= read -r t; do
            [[ -z "$t" ]] && continue
            victim="$t"
            $RELEASE && victim="$t/release"
            [[ -d "$victim" ]] || continue
            echo "[orphan] ${victim#"$WORKSPACE_ROOT"/}"
            if ! $DRY_RUN; then
                rm -rf -- "$victim"
            fi
            ORPHANS=$((ORPHANS + 1))
        done < <(find "$WORKSPACE_ROOT/$parent" -mindepth 2 -maxdepth 2 -type d -name target 2>/dev/null)
    done
fi

echo
echo "Summary: meta_workspaces_cleaned=$CLEANED skipped=$SKIPPED failed=$FAILED orphans_pruned=$ORPHANS"
$DRY_RUN && echo "(dry-run — nothing was actually removed)"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
