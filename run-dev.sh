#!/usr/bin/env bash
# run-dev.sh — Build all HomeCore components (debug) then start the server.
#
# Discovers every plugin under plugins/ that contains a Cargo.toml and builds
# it, then builds homecore, then runs the server.
#
# Usage:
#   ./run-dev.sh [OPTIONS]
#
# Options:
#   --no-pull       Skip git pull in all repos (default: pull before building)
#   --no-build      Skip all cargo builds; use existing binaries as-is
#   --release       Build and run release binaries (default: debug)
#   --help          Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMECORE_SRC="$WORKSPACE_ROOT/core"
CONFIG="config/homecore.dev.toml"
PULL=true
BUILD=true
PROFILE="debug"
CARGO_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull)  PULL=false; shift ;;
        --no-build) BUILD=false; shift ;;
        --release)  PROFILE="release"; CARGO_FLAG="--release"; shift ;;
        --help|-h)
            sed -n '2,/^set /p' "$0" | grep -E '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Collect repos
# ---------------------------------------------------------------------------

# SDK repos (must be pulled + built before plugins that depend on them)
SDK_DIRS=()
for dir in "$WORKSPACE_ROOT"/sdks/hc-plugin-sdk-*/; do
    [[ -d "$dir" ]] && SDK_DIRS+=("$dir")
done

# Plugin repos with a Cargo.toml
PLUGIN_DIRS=()
for dir in "$WORKSPACE_ROOT"/plugins/hc-*/; do
    [[ -f "${dir}Cargo.toml" ]] && PLUGIN_DIRS+=("$dir")
done

# Client repos (pulled but not built here)
CLIENT_DIRS=()
for dir in "$WORKSPACE_ROOT"/clients/hc-*/; do
    [[ -d "${dir}.git" ]] && CLIENT_DIRS+=("$dir")
done

# ---------------------------------------------------------------------------
# Pull phase
# ---------------------------------------------------------------------------

if $PULL; then
    # Pull ourselves first so the rest of the script is up to date on next run
    SELF_DIR="$SCRIPT_DIR"
    if [[ -d "$SELF_DIR/.git" ]]; then
        printf "    %-25s  " "hc-scripts (self)"
        branch=$(git -C "$SELF_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        printf "[%s]  " "$branch"
        if git -C "$SELF_DIR" pull --ff-only --quiet 2>/dev/null; then
            echo "ok"
        else
            echo "WARN: pull failed (offline or dirty?)" >&2
        fi
    fi

    PULL_DIRS=("$HOMECORE_SRC" "${SDK_DIRS[@]}" "${PLUGIN_DIRS[@]}" "${CLIENT_DIRS[@]}")
    TOTAL_PULL=${#PULL_DIRS[@]}
    echo "==> Pulling $TOTAL_PULL repos"
    echo

    for dir in "${PULL_DIRS[@]}"; do
        name="$(basename "$dir")"
        [[ -d "${dir}.git" ]] || continue
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        printf "    %-25s  [%s]  " "$name" "$branch"
        if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
            echo "ok"
        else
            echo "WARN: pull failed (offline or dirty?) — continuing with local state" >&2
        fi
    done
    echo
fi

# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------

if $BUILD; then
    TOTAL=$(( ${#PLUGIN_DIRS[@]} + 1 ))   # plugins + homecore
    FAILED=()
    STEP=0

    echo "==> Building $TOTAL Rust crates ($PROFILE)"
    echo

    # Build each hc-* plugin repo. A plugin build failure warns but does not
    # abort — homecore can still start with a stale binary for that plugin.
    for dir in "${PLUGIN_DIRS[@]}"; do
        name="$(basename "$dir")"
        STEP=$(( STEP + 1 ))
        echo "[$STEP/$TOTAL] $name"

        if cargo build ${CARGO_FLAG:+"$CARGO_FLAG"} --manifest-path "${dir}Cargo.toml" 2>&1; then
            echo "  ok"
        else
            echo "  WARN: $name build failed — stale binary will be used" >&2
            FAILED+=("$name")
        fi
        echo
    done

    # Build homecore last.  Failure here is fatal — nothing to start.
    STEP=$(( STEP + 1 ))
    echo "[$STEP/$TOTAL] homecore"
    if ! cargo build ${CARGO_FLAG:+"$CARGO_FLAG"} --manifest-path "$HOMECORE_SRC/Cargo.toml" --bin homecore 2>&1; then
        echo
        echo "ERROR: homecore build failed — cannot start." >&2
        exit 1
    fi
    echo "  ok"
    echo

    # Summary
    if [[ ${#FAILED[@]} -eq 0 ]]; then
        echo "==> All $TOTAL builds succeeded"
    else
        echo "==> Build complete — ${#FAILED[@]} plugin(s) failed: ${FAILED[*]}"
        echo "    Continuing with stale binaries for those plugins."
    fi
    echo
fi

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

BINARY="$HOMECORE_SRC/target/$PROFILE/homecore"

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: binary not found: $BINARY" >&2
    echo "       Run without --no-build or build first." >&2
    exit 1
fi

echo "==> Starting HomeCore (dev)"
echo "    home  : $HOMECORE_SRC"
echo "    config: $CONFIG"
echo "    binary: $BINARY"
echo

exec "$BINARY" --home "$HOMECORE_SRC" --config "$CONFIG"
