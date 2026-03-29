#!/usr/bin/env bash
# ensure-chip-tool.sh — Stage a chip-tool binary for hc-matter at plugins/hc-matter/bin/chip-tool.
#
# Resolution order:
# 1) existing staged binary
# 2) CHIP_TOOL_SOURCE env var
# 3) chip-tool found on PATH
# 4) common local SDK output paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HC_MATTER_DIR="$WORKSPACE_ROOT/plugins/hc-matter"
TARGET_DIR="$HC_MATTER_DIR/bin"
TARGET_BIN="$TARGET_DIR/chip-tool"
HC_MATTER_BUILD_SCRIPT="$HC_MATTER_DIR/scripts/build-chip-tool.sh"

log() { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    [warn] $*"; }

is_executable_file() {
    local path="$1"
    [[ -f "$path" && -x "$path" ]]
}

install_candidate() {
    local src="$1"
    mkdir -p "$TARGET_DIR"
    install -m 755 "$src" "$TARGET_BIN"
    info "staged chip-tool: ${TARGET_BIN#$WORKSPACE_ROOT/}"
}

if is_executable_file "$TARGET_BIN"; then
    info "chip-tool already staged: ${TARGET_BIN#$WORKSPACE_ROOT/}"
    exit 0
fi

if [[ -n "${CHIP_TOOL_SOURCE:-}" ]]; then
    if is_executable_file "$CHIP_TOOL_SOURCE"; then
        log "Using CHIP_TOOL_SOURCE"
        install_candidate "$CHIP_TOOL_SOURCE"
        exit 0
    fi
    warn "CHIP_TOOL_SOURCE is set but not executable: $CHIP_TOOL_SOURCE"
fi

if command -v chip-tool >/dev/null 2>&1; then
    src="$(command -v chip-tool)"
    log "Using chip-tool from PATH"
    install_candidate "$src"
    exit 0
fi

CANDIDATES=(
    "$HC_MATTER_DIR/third_party/connectedhomeip/out/chip-tool/chip-tool"
    "$HC_MATTER_DIR/third_party/connectedhomeip/out/chip-tool/linux_x64/chip-tool"
    "$HC_MATTER_DIR/third_party/connectedhomeip/out/host/chip-tool"
    "$WORKSPACE_ROOT/third_party/connectedhomeip/out/chip-tool/chip-tool"
    "$WORKSPACE_ROOT/third_party/connectedhomeip/out/chip-tool/linux_x64/chip-tool"
    "$WORKSPACE_ROOT/third_party/connectedhomeip/out/host/chip-tool"
    "$HOME/connectedhomeip/out/chip-tool/chip-tool"
)

for candidate in "${CANDIDATES[@]}"; do
    if is_executable_file "$candidate"; then
        log "Using local CHIP SDK artifact"
        install_candidate "$candidate"
        exit 0
    fi
done

if [[ -x "$HC_MATTER_BUILD_SCRIPT" ]]; then
    log "Attempting chip-tool build from hc-matter submodule"
    if "$HC_MATTER_BUILD_SCRIPT"; then
        if is_executable_file "$TARGET_BIN"; then
            info "chip-tool build succeeded: ${TARGET_BIN#$WORKSPACE_ROOT/}"
            exit 0
        fi
    else
        warn "auto-build failed from hc-matter/scripts/build-chip-tool.sh"
    fi
fi

warn "chip-tool could not be provisioned automatically"
warn "Set CHIP_TOOL_SOURCE to a built chip-tool binary, or install chip-tool in PATH"
warn "Expected staged path: ${TARGET_BIN#$WORKSPACE_ROOT/}"
exit 1
