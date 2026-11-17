#!/usr/bin/env bash
# build-release.sh: release-build everything homeCore builds from a workspace
# checkout, in place. Nothing is installed; deploy.sh does that.
#
# What it builds:
#   core          cargo build --release --workspace in core/: the server, its
#                 crates, the Rust SDK and every Rust plugin (core/plugins/),
#                 one cargo run into core/target/.
#   hc-tui        the terminal client, its own repo and lockfile (--locked).
#   hc-web-svelte the web app: npm ci && npm run build, into its build/.
#
# Not built here: the non-Rust plugins (hc-matter, hc-plugins-py) and the
# Python, JS and .NET SDKs, which have their own release workflows.
#
# Usage:
#   ./build-release.sh [OPTIONS]
#
# Options:
#   --no-pull       Skip git pull before building
#   --no-web        Skip the web app (no node or npm needed)
#   --target TRIPLE Cross-compile the Rust builds (e.g. aarch64-unknown-linux-musl)
#   --dry-run       Print what would be pulled and built, then exit
#   --help          Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMECORE_SRC="$WORKSPACE_ROOT/core"
TUI_SRC="$WORKSPACE_ROOT/clients/hc-tui"
WEB_SRC="$WORKSPACE_ROOT/clients/hc-web-svelte"

PULL=true
WEB=true
DRY_RUN=false
TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull)   PULL=false; shift ;;
        --no-web)    WEB=false; shift ;;
        --target)
            [[ $# -ge 2 ]] || { echo "ERROR: --target needs a triple" >&2; exit 1; }
            TARGET_ARGS=(--target "$2"); shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '2,/^set /p' "$0" | grep -E '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# What is present
# ---------------------------------------------------------------------------

if [[ ! -f "$HOMECORE_SRC/Cargo.toml" ]]; then
    echo "ERROR: core not found at $HOMECORE_SRC (run workspace-clone.sh first)" >&2
    exit 1
fi

# name|dir|kind, for the components that are cloned
STEPS=("core|$HOMECORE_SRC|cargo-workspace")
if [[ -f "$TUI_SRC/Cargo.toml" ]]; then
    STEPS+=("hc-tui|$TUI_SRC|cargo")
else
    echo "    [skip] hc-tui not cloned at $TUI_SRC"
fi
if $WEB; then
    if [[ -f "$WEB_SRC/package.json" ]]; then
        STEPS+=("hc-web-svelte|$WEB_SRC|npm")
    else
        echo "    [skip] hc-web-svelte not cloned at $WEB_SRC"
    fi
fi

step_cmd() {
    local dir="$1" kind="$2"
    case "$kind" in
        cargo-workspace) echo "cargo build --release --workspace ${TARGET_ARGS[*]-} --manifest-path $dir/Cargo.toml" ;;
        cargo)           echo "cargo build --release --locked ${TARGET_ARGS[*]-} --manifest-path $dir/Cargo.toml" ;;
        npm)             echo "(cd $dir && npm ci && npm run build)" ;;
    esac
}

echo "========================================"
echo " HomeCore Release Builder"
echo "========================================"
for s in "${STEPS[@]}"; do
    IFS='|' read -r name dir kind <<< "$s"
    printf "  %-14s %s\n" "$name" "$dir"
done
[[ ${#TARGET_ARGS[@]} -gt 0 ]] && echo "  Target         ${TARGET_ARGS[1]}"
echo "========================================"
echo

if $DRY_RUN; then
    echo "==> Would run"
    for s in "${STEPS[@]}"; do
        IFS='|' read -r name dir kind <<< "$s"
        if $PULL && [[ -d "$dir/.git" ]]; then
            echo "    git -C $dir pull --ff-only"
        fi
        echo "    $(step_cmd "$dir" "$kind")"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Check tools
# ---------------------------------------------------------------------------

command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not found on PATH" >&2; exit 1; }
for s in "${STEPS[@]}"; do
    IFS='|' read -r name dir kind <<< "$s"
    if [[ "$kind" == "npm" ]] && ! command -v npm >/dev/null 2>&1; then
        echo "ERROR: npm not found on PATH (needed for $name; --no-web skips it)" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Pull phase
# ---------------------------------------------------------------------------

if $PULL; then
    echo "==> Pulling"
    for s in "${STEPS[@]}"; do
        IFS='|' read -r name dir kind <<< "$s"
        [[ -d "$dir/.git" ]] || continue
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        printf "    %-16s [%s]  " "$name" "$branch"
        if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
            echo "ok"
        else
            echo "skip (dirty or offline)"
        fi
    done
    echo
fi

# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------

START_TIME=$SECONDS
FAILED=()
SUCCEEDED=0
STEP=0

run_step() {
    local dir="$1" kind="$2"
    case "$kind" in
        cargo-workspace)
            cargo build --release --workspace ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} \
                --manifest-path "$dir/Cargo.toml" ;;
        cargo)
            cargo build --release --locked ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} \
                --manifest-path "$dir/Cargo.toml" ;;
        npm)
            (cd "$dir" && npm ci && npm run build) ;;
    esac
}

for s in "${STEPS[@]}"; do
    IFS='|' read -r name dir kind <<< "$s"
    STEP=$(( STEP + 1 ))
    echo "==> [$STEP/${#STEPS[@]}] $name: $(step_cmd "$dir" "$kind")"
    if run_step "$dir" "$kind"; then
        echo "    ok"
        SUCCEEDED=$(( SUCCEEDED + 1 ))
    else
        echo "    FAILED" >&2
        FAILED+=("$name")
    fi
    echo
done

ELAPSED=$(( SECONDS - START_TIME ))

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "========================================"
echo " Release build complete"
echo "========================================"
echo "  Built    : $SUCCEEDED / ${#STEPS[@]}"
echo "  Time     : ${ELAPSED}s"
echo "  Binaries : $HOMECORE_SRC/target/ (core and every Rust plugin)"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo
    echo "  FAILURES : ${FAILED[*]}"
    exit 1
fi

echo "========================================"
