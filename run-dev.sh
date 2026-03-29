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
#   --no-build      Skip all cargo builds; use existing binaries as-is
#   --release       Build and run release binaries (default: debug)
#   --help          Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMECORE_SRC="$WORKSPACE_ROOT/core"
CONFIG="config/homecore.dev.toml"
BUILD=true
PROFILE="debug"
CARGO_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
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
# Build phase
# ---------------------------------------------------------------------------

#CHIP_TOOL_BOOTSTRAP="$WORKSPACE_ROOT/scripts/ensure-chip-tool.sh"
#if [[ -x "$CHIP_TOOL_BOOTSTRAP" ]]; then
#    if ! "$CHIP_TOOL_BOOTSTRAP"; then
#        echo "  WARN: chip-tool provisioning failed; hc-matter commissioning will report degraded health" >&2
#        echo
#    fi
#fi

if $BUILD; then
    # Collect all plugin repos that have a Cargo.toml
    PLUGIN_DIRS=()
    for dir in "$WORKSPACE_ROOT"/plugins/hc-*/; do
        [[ -f "${dir}Cargo.toml" ]] && PLUGIN_DIRS+=("$dir")
    done

    TOTAL=$(( ${#PLUGIN_DIRS[@]} + 1 ))   # plugins + homecore
    FAILED=()
    STEP=0

    echo "==> Building $TOTAL Rust crates ($PROFILE)"
    echo

    # Build each hc-* plugin repo.  A plugin build failure warns but does not
    # abort — homecore can still start with a stale binary for that plugin.
    for dir in "${PLUGIN_DIRS[@]}"; do
        name="$(basename "$dir")"
        STEP=$(( STEP + 1 ))
        echo "[$STEP/$TOTAL] $name"
        BUILD_FEATURES=""
#        if [[ "$name" == "hc-matter" ]]; then
#            BUILD_FEATURES="--features matter-stack"
#        fi

        if cargo build $CARGO_FLAG $BUILD_FEATURES --manifest-path "${dir}Cargo.toml" 2>&1; then
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
    if ! cargo build $CARGO_FLAG --manifest-path "$HOMECORE_SRC/Cargo.toml" --bin homecore 2>&1; then
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
