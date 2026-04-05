#!/usr/bin/env bash
# build-release.sh — Build optimized release binaries for all HomeCore components.
#
# Discovers all Rust crates (core, plugins, clients) and builds them with
# --release.  Non-Rust projects (Node.js, Flutter) are skipped with a note.
#
# Usage:
#   ./build-release.sh [OPTIONS]
#
# Options:
#   --no-pull       Skip git pull before building
#   --parallel      Build plugins in parallel (faster, noisier output)
#   --target TRIPLE Cross-compile for a specific target (e.g. aarch64-unknown-linux-musl)
#   --help          Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMECORE_SRC="$WORKSPACE_ROOT/core"

PULL=true
PARALLEL=false
TARGET=""
CARGO_TARGET_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull)   PULL=false; shift ;;
        --parallel)  PARALLEL=true; shift ;;
        --target)    TARGET="$2"; CARGO_TARGET_FLAG="--target $2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^set /p' "$0" | grep -E '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Discover all repos
# ---------------------------------------------------------------------------

RUST_DIRS=()
NODE_DIRS=()
FLUTTER_DIRS=()
SKIPPED_DIRS=()

# Core
RUST_DIRS+=("$HOMECORE_SRC")

# Plugins
for dir in "$WORKSPACE_ROOT"/plugins/hc-*/; do
    [[ -d "$dir" ]] || continue
    if [[ -f "${dir}Cargo.toml" ]]; then
        RUST_DIRS+=("$dir")
    elif [[ -f "${dir}package.json" ]]; then
        NODE_DIRS+=("$dir")
    else
        SKIPPED_DIRS+=("$dir")
    fi
done

# Clients
for dir in "$WORKSPACE_ROOT"/clients/hc-*/; do
    [[ -d "$dir" ]] || continue
    if [[ -f "${dir}Cargo.toml" ]]; then
        RUST_DIRS+=("$dir")
    elif [[ -f "${dir}package.json" ]]; then
        NODE_DIRS+=("$dir")
    elif [[ -f "${dir}pubspec.yaml" ]]; then
        FLUTTER_DIRS+=("$dir")
    else
        SKIPPED_DIRS+=("$dir")
    fi
done

TOTAL_RUST=${#RUST_DIRS[@]}
TOTAL_NODE=${#NODE_DIRS[@]}
TOTAL_FLUTTER=${#FLUTTER_DIRS[@]}
TOTAL_SKIP=${#SKIPPED_DIRS[@]}

echo "========================================"
echo " HomeCore Release Builder"
echo "========================================"
echo "  Rust crates  : $TOTAL_RUST"
echo "  Node.js      : $TOTAL_NODE"
echo "  Flutter      : $TOTAL_FLUTTER"
[[ $TOTAL_SKIP -gt 0 ]] && echo "  Skipped      : $TOTAL_SKIP"
[[ -n "$TARGET" ]] && echo "  Target       : $TARGET"
echo "========================================"
echo

# ---------------------------------------------------------------------------
# Pull phase
# ---------------------------------------------------------------------------

if $PULL; then
    ALL_DIRS=("${RUST_DIRS[@]}" "${NODE_DIRS[@]}" "${FLUTTER_DIRS[@]}")
    echo "==> Pulling ${#ALL_DIRS[@]} repos"
    echo
    for dir in "${ALL_DIRS[@]}"; do
        name="$(basename "$dir")"
        [[ -d "${dir}.git" ]] || continue
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        printf "    %-25s [%s]  " "$name" "$branch"
        if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
            echo "ok"
        else
            echo "skip (dirty or offline)"
        fi
    done
    echo
fi

# ---------------------------------------------------------------------------
# Rust build phase
# ---------------------------------------------------------------------------

START_TIME=$SECONDS
FAILED=()
SUCCEEDED=0
STEP=0

echo "==> Building $TOTAL_RUST Rust crates (release)"
echo

build_rust() {
    local dir="$1"
    local name="$(basename "$dir")"
    local manifest="${dir}Cargo.toml"

    if cargo build --release $CARGO_TARGET_FLAG --manifest-path "$manifest" 2>&1; then
        return 0
    else
        return 1
    fi
}

if $PARALLEL; then
    echo "    (parallel mode — output interleaved)"
    echo
    PIDS=()
    NAMES=()
    for dir in "${RUST_DIRS[@]}"; do
        name="$(basename "$dir")"
        NAMES+=("$name")
        build_rust "$dir" &
        PIDS+=($!)
    done

    for i in "${!PIDS[@]}"; do
        if wait "${PIDS[$i]}"; then
            echo "  ✓ ${NAMES[$i]}"
            SUCCEEDED=$(( SUCCEEDED + 1 ))
        else
            echo "  ✗ ${NAMES[$i]} FAILED"
            FAILED+=("${NAMES[$i]}")
        fi
    done
else
    for dir in "${RUST_DIRS[@]}"; do
        name="$(basename "$dir")"
        STEP=$(( STEP + 1 ))
        echo "[$STEP/$TOTAL_RUST] $name"
        if build_rust "$dir"; then
            echo "  ok"
            SUCCEEDED=$(( SUCCEEDED + 1 ))
        else
            echo "  FAILED" >&2
            FAILED+=("$name")
        fi
        echo
    done
fi

ELAPSED=$(( SECONDS - START_TIME ))

echo
echo "==> Rust builds: $SUCCEEDED succeeded, ${#FAILED[@]} failed (${ELAPSED}s)"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "    Failed: ${FAILED[*]}"
fi
echo

# ---------------------------------------------------------------------------
# Node.js build phase
# ---------------------------------------------------------------------------

if [[ $TOTAL_NODE -gt 0 ]]; then
    echo "==> Building $TOTAL_NODE Node.js projects"
    echo
    for dir in "${NODE_DIRS[@]}"; do
        name="$(basename "$dir")"
        echo "[$name]"
        if [[ -f "${dir}package-lock.json" ]] || [[ -f "${dir}pnpm-lock.yaml" ]]; then
            if command -v npm &>/dev/null; then
                (cd "$dir" && npm ci --silent 2>/dev/null && npm run build 2>&1) && echo "  ok" || echo "  FAILED"
            else
                echo "  skip (npm not found)"
            fi
        else
            echo "  skip (no lockfile)"
        fi
        echo
    done
fi

# ---------------------------------------------------------------------------
# Flutter build phase
# ---------------------------------------------------------------------------

if [[ $TOTAL_FLUTTER -gt 0 ]]; then
    echo "==> Building $TOTAL_FLUTTER Flutter projects"
    echo
    for dir in "${FLUTTER_DIRS[@]}"; do
        name="$(basename "$dir")"
        echo "[$name]"
        if command -v flutter &>/dev/null; then
            (cd "$dir" && flutter build web --release 2>&1) && echo "  ok" || echo "  FAILED"
        else
            echo "  skip (flutter not found)"
        fi
        echo
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "========================================"
echo " Release build complete"
echo "========================================"
echo "  Rust     : $SUCCEEDED / $TOTAL_RUST built"
[[ $TOTAL_NODE -gt 0 ]] && echo "  Node.js  : $TOTAL_NODE projects"
[[ $TOTAL_FLUTTER -gt 0 ]] && echo "  Flutter  : $TOTAL_FLUTTER projects"
echo "  Time     : ${ELAPSED}s"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo
    echo "  FAILURES : ${FAILED[*]}"
    exit 1
fi

echo "========================================"
