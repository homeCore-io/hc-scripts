#!/usr/bin/env bash
# run-dev.sh — Build homecore and every Rust plugin (debug), then start the server.
#
# core/ is one cargo workspace holding the server and every Rust plugin
# (core/plugins/hc-*), so everything builds there, into core/target/, which
# is where config/homecore.dev.toml points each plugin's binary.
#
# NOT sandboxed: homecore.dev.toml runs the real plugin configs against the
# real hubs and cloud accounts. Use a sandbox for anything destructive.
#
# Usage:
#   ./run-dev.sh [OPTIONS]
#
# Options:
#   --no-pull       Skip git pull in all repos (default: pull before building)
#   --no-update     Skip 'cargo update' after pull (default: refresh core's Cargo.lock)
#   --no-build      Skip all cargo builds; use existing binaries as-is
#   --release       Build and run release binaries (default: debug)
#   --webui         Also start the web app's dev server (clients/hc-web-svelte,
#                   `npm run dev` on :5180), pointed at this core
#   --help          Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMECORE_SRC="$WORKSPACE_ROOT/core"
CONFIG="config/homecore.dev.toml"
PULL=true
UPDATE=true
BUILD=true
WEBUI=false
PROFILE="debug"
CARGO_FLAG=""
WEBUI_DIR="$WORKSPACE_ROOT/clients/hc-web-svelte"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull)   PULL=false; shift ;;
        --no-update) UPDATE=false; shift ;;
        --no-build)  BUILD=false; shift ;;
        --release)   PROFILE="release"; CARGO_FLAG="--release"; shift ;;
        --webui)     WEBUI=true; shift ;;
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

# Plugins that are their own repos (not Rust, so not in core's workspace):
# pulled, not built here.
PLUGIN_DIRS=()
for dir in "$WORKSPACE_ROOT"/plugins/hc-*/; do
    [[ -d "${dir}.git" ]] && PLUGIN_DIRS+=("$dir")
done

# The Rust plugins, as members of core's workspace.
CORE_PLUGINS=()
for dir in "$HOMECORE_SRC"/plugins/hc-*/; do
    [[ -f "${dir}Cargo.toml" ]] && CORE_PLUGINS+=("$(basename "$dir")")
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
# Refresh phase — bump core's Cargo.lock to the latest semver-compatible
# deps. This changes a committed file; --no-update skips it.
#
# Skipped if --no-update or --no-pull (no point if source didn't move).
# ---------------------------------------------------------------------------

if $PULL && $UPDATE; then
    printf "==> cargo update in core  "
    if cargo update --quiet --manifest-path "$HOMECORE_SRC/Cargo.toml" 2>/dev/null; then
        echo "ok"
    else
        echo "WARN: cargo update failed (offline or registry blip?)" >&2
    fi
    echo
fi

# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------

if $BUILD; then
    TOTAL=$(( ${#CORE_PLUGINS[@]} + 1 ))   # plugins + homecore
    FAILED=()

    echo "==> Building $TOTAL Rust crates in core's workspace ($PROFILE)"
    echo

    # homecore first. Failure here is fatal: there is nothing to start.
    echo "[1/$TOTAL] homecore"
    if ! cargo build ${CARGO_FLAG:+"$CARGO_FLAG"} --manifest-path "$HOMECORE_SRC/Cargo.toml" --bin homecore 2>&1; then
        echo
        echo "ERROR: homecore build failed — cannot start." >&2
        exit 1
    fi
    echo "  ok"
    echo

    # Each plugin on its own, so one that fails only warns: homecore can
    # start with that plugin's previous binary.
    STEP=1
    for name in "${CORE_PLUGINS[@]}"; do
        STEP=$(( STEP + 1 ))
        echo "[$STEP/$TOTAL] $name"
        if cargo build ${CARGO_FLAG:+"$CARGO_FLAG"} --manifest-path "$HOMECORE_SRC/Cargo.toml" -p "$name" 2>&1; then
            echo "  ok"
        else
            echo "  WARN: $name build failed — stale binary will be used" >&2
            FAILED+=("$name")
        fi
        echo
    done

    # Summary
    if [[ ${#FAILED[@]} -eq 0 ]]; then
        echo "==> All builds succeeded"
    else
        echo "==> Build complete — ${#FAILED[@]} component(s) failed: ${FAILED[*]}"
        echo "    Continuing with stale binaries for those components."
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

# ---------------------------------------------------------------------------
# Web UI — the app's dev server, as a background process
# ---------------------------------------------------------------------------
#
# The app (clients/hc-web-svelte) calls /api/v1 relatively, and core sends no
# CORS headers, so its own server passes the API through to core same-origin.
# `npm run dev` runs that server with Vite's hot reload, on :5180, and
# HC_CORE_URL tells it where this core is.

WEBUI_PID=""

cleanup() {
    if [[ -n "$WEBUI_PID" ]]; then
        echo "==> Stopping the web app's dev server (pid $WEBUI_PID)"
        kill "$WEBUI_PID" 2>/dev/null
        wait "$WEBUI_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

if $WEBUI; then
    if [[ ! -f "$WEBUI_DIR/package.json" ]]; then
        echo "WARN: $WEBUI_DIR not found — skipping --webui" >&2
    else
        HC_PORT="$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
                    "$HOMECORE_SRC/$CONFIG" | head -1)"
        HC_PORT="${HC_PORT:-8080}"
        [[ -d "$WEBUI_DIR/node_modules" ]] || ( cd "$WEBUI_DIR" && npm install )
        echo "==> Starting the web app's dev server (:5180 -> core :$HC_PORT)"
        ( cd "$WEBUI_DIR" && HC_CORE_URL="http://127.0.0.1:$HC_PORT" npm run dev ) &
        WEBUI_PID=$!
        echo "    pid: $WEBUI_PID"
        echo "    Open http://localhost:5180"
        echo
    fi
fi

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

echo "==> Starting HomeCore (dev)"
echo "    home  : $HOMECORE_SRC"
echo "    config: $CONFIG"
echo "    binary: $BINARY"
echo

"$BINARY" --home "$HOMECORE_SRC" --config "$CONFIG"
