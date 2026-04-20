#!/usr/bin/env bash
# deploy.sh — Build and install HomeCore to a prod-like local environment.
#
# DESTINATION LAYOUT
# ==================
#   $DEST/
#     bin/
#       homecore                       ← main binary
#     config/
#       homecore.toml                  ← main config (preserved; --force-config to overwrite)
#       profiles/                      ← ecosystem profiles (all files, recursively)
#     rules/                           ← automation rule RON files
#     data/                            ← state.redb, history.db  (runtime, not deployed)
#     logs/                            ← homecore rolling logs    (runtime, not deployed)
#     ui/
#       dist/                          ← Leptos/WASM admin UI (trunk build output)
#     scripts/
#       service-templates/             ← systemd / launchd unit templates
#     plugins/
#       hc-yolink/
#         bin/hc-yolink                ← plugin binary
#         config/config.toml           ← plugin config (preserved; --force-config to overwrite)
#         logs/                        ← plugin logs land here automatically
#       hc-lutron/  hc-sonos/  hc-hue/  hc-zwave/
#         (same structure as above)
#
# NOTE: Plugin log dirs are derived automatically by the plugin from its config
# path (Path::new(config_path).parent().parent().join("logs")), so as long as
# config is deployed to plugins/<name>/config/config.toml the logs go to
# plugins/<name>/logs/ with no extra wiring required.
#
# USAGE
# =====
#   ./deploy.sh [OPTIONS] [COMPONENT...]
#
# COMPONENTS
#   homecore      Main HomeCore server
#   hc-web        Leptos/WASM admin UI (requires trunk)
#   hc-yolink     YoLink cloud MQTT bridge
#   hc-lutron     Lutron RadioRA2 telnet bridge
#   hc-sonos      Sonos UPnP bridge
#   hc-hue        Philips Hue bridge
#   hc-wled       WLED LED controller
#   hc-zwave      Z-Wave JS WebSocket bridge
#   hc-isy        ISY994 / Polisy / eISY bridge
#   hc-caseta     Lutron Caseta Pro bridge
#   hc-ecowitt    Ecowitt weather station gateway
#
# OPTIONS
#   --all           Build and install all components (default when none specified)
#   --no-build      Skip cargo build; install already-built release binaries
#   --sync-config   Copy configs from source (skips files that already exist)
#   --force-config  Overwrite configs from source even if they already exist
#   --dest DIR      Installation directory (default: /var/tmp/homeCore)
#   --debug         Build debug instead of release
#   --help          Show this help

set -euo pipefail

# ===========================================================================
# DEFAULTS
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="/var/tmp/homeCore"
BUILD=true
SYNC_CONFIG=false
FORCE_CONFIG=false
RELEASE_FLAG="--release"
RELEASE_DIR="release"
COMPONENTS=()

# ---------------------------------------------------------------------------
# Source paths
# ---------------------------------------------------------------------------

HOMECORE_SRC="$WORKSPACE_ROOT/core"
WEBUI_SRC="$WORKSPACE_ROOT/clients/hc-web-leptos"

# ===========================================================================
# PLUGIN REGISTRY
# ===========================================================================
#
# To add a new plugin:
#   1. Add the name to PLUGINS array
#   2. Add its source directory to PLUGIN_SRC_DIR
#   3. Add the repo to workspace.toml
#   4. Ensure its source has config/config.toml.example
#
# Each plugin is automatically deployed to:
#   $DEST/plugins/<name>/bin/<name>
#   $DEST/plugins/<name>/config/config.toml  (from source config/config.toml)
#   $DEST/plugins/<name>/logs/               (empty dir, logs land here at runtime)

PLUGINS=(
    hc-yolink
    hc-lutron
    hc-caseta
    hc-sonos
    hc-hue
    hc-wled
    hc-zwave
    hc-isy
    hc-ecowitt
    hc-thermostat
)

declare -A PLUGIN_SRC_DIR=(
    [hc-yolink]="$WORKSPACE_ROOT/plugins/hc-yolink"
    [hc-lutron]="$WORKSPACE_ROOT/plugins/hc-lutron"
    [hc-caseta]="$WORKSPACE_ROOT/plugins/hc-caseta"
    [hc-sonos]="$WORKSPACE_ROOT/plugins/hc-sonos"
    [hc-hue]="$WORKSPACE_ROOT/plugins/hc-hue"
    [hc-wled]="$WORKSPACE_ROOT/plugins/hc-wled"
    [hc-zwave]="$WORKSPACE_ROOT/plugins/hc-zwave"
    [hc-isy]="$WORKSPACE_ROOT/plugins/hc-isy"
    [hc-ecowitt]="$WORKSPACE_ROOT/plugins/hc-ecowitt"
    [hc-thermostat]="$WORKSPACE_ROOT/plugins/hc-thermostat"
)

ALL_COMPONENTS=(homecore hc-web "${PLUGINS[@]}")

# ===========================================================================
# ARGUMENT PARSING
# ===========================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          COMPONENTS=("${ALL_COMPONENTS[@]}"); shift ;;
        --no-build)     BUILD=false; shift ;;
        --sync-config)  SYNC_CONFIG=true; shift ;;
        --force-config) FORCE_CONFIG=true; SYNC_CONFIG=true; shift ;;
        --dest)         DEST="$2"; shift 2 ;;
        --debug)        RELEASE_FLAG=""; RELEASE_DIR="debug"; shift ;;
        --help|-h)
            sed -n '/^# USAGE/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            valid=false
            for c in "${ALL_COMPONENTS[@]}"; do [[ "$1" == "$c" ]] && valid=true && break; done
            if ! $valid; then
                echo "ERROR: Unknown component: $1" >&2
                echo "       Valid: ${ALL_COMPONENTS[*]}" >&2
                exit 1
            fi
            COMPONENTS+=("$1")
            shift
            ;;
    esac
done

# Default to --all when nothing is specified
if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
    COMPONENTS=("${ALL_COMPONENTS[@]}")
fi

# ===========================================================================
# HELPERS
# ===========================================================================

log()  { echo "==> $*"; }
info() { echo "    $*"; }
ok()   { echo "    [ok]     $*"; }
skip() { echo "    [skip]   $*"; }
warn() { echo "    [warn]   $*"; }

# Return 0 if a component's source directory exists and is buildable
check_source() {
    local comp="$1"
    if [[ "$comp" == "homecore" ]]; then
        [[ -f "$HOMECORE_SRC/Cargo.toml" ]]
    elif [[ "$comp" == "hc-web" ]]; then
        [[ -f "$WEBUI_SRC/Trunk.toml" ]]
    else
        local dir="${PLUGIN_SRC_DIR[$comp]:-}"
        [[ -n "$dir" && -f "$dir/Cargo.toml" ]]
    fi
}

# Print the path to a built binary for a component
binary_src_path() {
    local comp="$1"
    if [[ "$comp" == "homecore" ]]; then
        echo "$HOMECORE_SRC/target/$RELEASE_DIR/homecore"
    else
        local dir="${PLUGIN_SRC_DIR[$comp]}"
        echo "$dir/target/$RELEASE_DIR/$comp"
    fi
}

# Copy a file from src to dst, respecting FORCE_CONFIG / SYNC_CONFIG.
# If dst already exists and FORCE_CONFIG is false: skip.
# Prints one info/skip line relative to DEST.
sync_file() {
    local src="$1"
    local dst="$2"
    local label="${dst#"$DEST/"}"

    if [[ -f "$dst" ]] && ! $FORCE_CONFIG; then
        skip "$label  (use --force-config to overwrite)"
        return
    fi

    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    if $FORCE_CONFIG && [[ -e "$dst" ]]; then
        info "[updated] $label"
    else
        info "[created] $label"
    fi
}

# ===========================================================================
# SCAFFOLD — create the destination directory tree (idempotent)
# ===========================================================================

scaffold_homecore() {
    log "Scaffolding homecore dirs under $DEST"
    mkdir -p "$DEST/bin"
    mkdir -p "$DEST/config/profiles"
    mkdir -p "$DEST/rules"
    mkdir -p "$DEST/data"
    mkdir -p "$DEST/logs"
    mkdir -p "$DEST/ui/dist"
    mkdir -p "$DEST/scripts/service-templates"
    info "bin/  config/  rules/  data/  logs/  ui/dist/  scripts/"

    # Copy scripts unconditionally — these are not credentials-bearing config files
    if [[ -d "$HOMECORE_SRC/scripts" ]]; then
        while IFS= read -r -d '' f; do
            local rel_path="${f#"$HOMECORE_SRC/scripts/"}"
            local dst="$DEST/scripts/$rel_path"
            mkdir -p "$(dirname "$dst")"
            cp "$f" "$dst"
            info "[copied]  scripts/$rel_path"
        done < <(find "$HOMECORE_SRC/scripts" -type f -print0)
    fi

    # Bootstrap homecore.toml from .example on first deploy (no --sync-config needed)
    local cfg_dst="$DEST/config/homecore.toml"
    local cfg_example="$HOMECORE_SRC/config/homecore.toml.example"
    if [[ ! -f "$cfg_dst" && -f "$cfg_example" ]]; then
        cp "$cfg_example" "$cfg_dst"
        info "[created] config/homecore.toml  (from .example — update credentials before running)"
    fi
}

scaffold_plugin() {
    local name="$1"
    log "Scaffolding plugin dirs: plugins/$name/"
    mkdir -p "$DEST/plugins/$name/bin"
    mkdir -p "$DEST/plugins/$name/config"
    mkdir -p "$DEST/plugins/$name/logs"
    info "plugins/$name/bin/  plugins/$name/config/  plugins/$name/logs/"
}

# ===========================================================================
# BUILD
# ===========================================================================

build_component() {
    local comp="$1"
    if [[ "$comp" == "homecore" ]]; then
        log "Building homecore ($RELEASE_DIR)"
        cargo build $RELEASE_FLAG --manifest-path "$HOMECORE_SRC/Cargo.toml"
    elif [[ "$comp" == "hc-web" ]]; then
        log "Building hc-web (trunk build --release)"
        trunk build --release --config "$WEBUI_SRC/Trunk.toml"
    else
        local dir="${PLUGIN_SRC_DIR[$comp]}"
        log "Building $comp ($RELEASE_DIR)"
        cargo build $RELEASE_FLAG --manifest-path "$dir/Cargo.toml"
    fi
}

# ===========================================================================
# INSTALL BINARIES
# ===========================================================================

install_homecore_binary() {
    local src
    src="$(binary_src_path homecore)"
    local dst="$DEST/bin/homecore"

    if [[ ! -f "$src" ]]; then
        echo "ERROR: homecore binary not found: $src" >&2
        echo "       Run without --no-build, or build first." >&2
        return 1
    fi

    cp "$src" "$dst"
    chmod 755 "$dst"
    ok "bin/homecore"
}

install_plugin_binary() {
    local name="$1"
    local src
    src="$(binary_src_path "$name")"
    local dst="$DEST/plugins/$name/bin/$name"

    if [[ ! -f "$src" ]]; then
        echo "ERROR: $name binary not found: $src" >&2
        echo "       Run without --no-build, or build first." >&2
        return 1
    fi

    cp "$src" "$dst"
    chmod 755 "$dst"
    ok "plugins/$name/bin/$name"
}

install_webui() {
    local src_dist="$WEBUI_SRC/dist"
    local dst_dist="$DEST/ui/dist"

    if [[ ! -d "$src_dist" ]]; then
        echo "ERROR: hc-web dist not found: $src_dist" >&2
        echo "       Run without --no-build, or run 'trunk build --release' first." >&2
        return 1
    fi

    # Clean previous build and sync fresh assets
    rm -rf "$dst_dist"
    mkdir -p "$dst_dist"
    cp -r "$src_dist/." "$dst_dist/"
    ok "ui/dist/  ($(find "$dst_dist" -type f | wc -l) files)"
}

# ===========================================================================
# SYNC CONFIGS  (--sync-config / --force-config)
# ===========================================================================

sync_homecore_config() {
    log "Syncing homecore config from source"

    # Main config (only if the real homecore.toml exists in source)
    local cfg="$HOMECORE_SRC/config/homecore.toml"
    [[ -f "$cfg" ]] && sync_file "$cfg" "$DEST/config/homecore.toml"

    # All ecosystem profiles — one recursive pass, no special-casing for subdirs
    if [[ -d "$HOMECORE_SRC/config/profiles" ]]; then
        while IFS= read -r -d '' f; do
            local rel_path="${f#"$HOMECORE_SRC/config/profiles/"}"
            sync_file "$f" "$DEST/config/profiles/$rel_path"
        done < <(find "$HOMECORE_SRC/config/profiles" -type f -print0)
    fi

    # Automation rules (live .ron files, not examples; also legacy .toml)
    if [[ -d "$HOMECORE_SRC/rules" ]]; then
        while IFS= read -r -d '' f; do
            [[ "$f" == */examples/* ]] && continue
            local rel_path="${f#"$HOMECORE_SRC/rules/"}"
            sync_file "$f" "$DEST/rules/$rel_path"
        done < <(find "$HOMECORE_SRC/rules" -type f \( -name "*.ron" -o -name "*.toml" \) -print0)
    fi

}

sync_plugin_config() {
    local name="$1"
    local src_dir="${PLUGIN_SRC_DIR[$name]}"

    # Prefer the real config; fall back to the example if not yet created
    local src="$src_dir/config/config.toml"
    if [[ ! -f "$src" ]]; then
        src="$src_dir/config/config.toml.example"
        if [[ ! -f "$src" ]]; then
            warn "$name: no config/config.toml or config/config.toml.example found — skipping"
            return
        fi
        warn "$name: config/config.toml not found; deploying .example (rename and fill in credentials)"
    fi

    sync_file "$src" "$DEST/plugins/$name/config/config.toml"
}

# ===========================================================================
# MAIN
# ===========================================================================

echo
log "HomeCore deploy"
info "Components : ${COMPONENTS[*]}"
info "Destination: $DEST"
info "Build mode : $RELEASE_DIR"
if $FORCE_CONFIG; then
    info "Sync config: $SYNC_CONFIG (force-overwrite)"
else
    info "Sync config: $SYNC_CONFIG"
fi
echo

# ---------------------------------------------------------------------------
# Pre-flight: verify all requested source dirs exist before doing any work
# ---------------------------------------------------------------------------
log "Checking source directories"
for comp in "${COMPONENTS[@]}"; do
    if ! check_source "$comp"; then
        if [[ "$comp" == "homecore" ]]; then
            echo "ERROR: homecore source not found at $HOMECORE_SRC" >&2
        elif [[ "$comp" == "hc-web" ]]; then
            echo "ERROR: hc-web source not found at $WEBUI_SRC (missing Trunk.toml)" >&2
        else
            echo "ERROR: $comp source not found at ${PLUGIN_SRC_DIR[$comp]:-<unknown>}" >&2
        fi
        exit 1
    fi
    info "found: $comp"
done
echo

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if $BUILD; then
    for comp in "${COMPONENTS[@]}"; do
        build_component "$comp"
        echo
    done
fi

# ---------------------------------------------------------------------------
# Scaffold destination directories
# ---------------------------------------------------------------------------
for comp in "${COMPONENTS[@]}"; do
    if [[ "$comp" == "homecore" ]]; then
        scaffold_homecore
    elif [[ "$comp" == "hc-web" ]]; then
        # ui/dist/ is created by scaffold_homecore; ensure it exists standalone too
        mkdir -p "$DEST/ui/dist"
    else
        scaffold_plugin "$comp"
    fi
done
echo

# ---------------------------------------------------------------------------
# Install binaries
# ---------------------------------------------------------------------------
log "Installing binaries"
for comp in "${COMPONENTS[@]}"; do
    if [[ "$comp" == "homecore" ]]; then
        install_homecore_binary
    elif [[ "$comp" == "hc-web" ]]; then
        install_webui
    else
        install_plugin_binary "$comp"
    fi
done
echo

# ---------------------------------------------------------------------------
# Sync configs
# ---------------------------------------------------------------------------
if $SYNC_CONFIG; then
    for comp in "${COMPONENTS[@]}"; do
        if [[ "$comp" == "homecore" ]]; then
            sync_homecore_config
        elif [[ "$comp" == "hc-web" ]]; then
            : # no config to sync for web UI
        else
            sync_plugin_config "$comp"
        fi
        echo
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "Deploy complete → $DEST"
echo

if [[ ! -f "$DEST/config/homecore.toml" ]]; then
    echo "  NOTE: $DEST/config/homecore.toml does not exist."
    echo "        Run with --sync-config to copy from source, or create manually."
    echo
fi

echo "  To enable the web UI, set in homecore.toml:"
echo "    [web_admin]"
echo "    enabled   = true"
echo "    dist_path = \"ui/dist\""
echo
echo "  Plugin binary paths in homecore.toml should be:"
for name in "${PLUGINS[@]}"; do
    echo "    binary = \"plugins/$name/bin/$name\""
done
echo
echo "  Plugin config args in homecore.toml should be:"
for name in "${PLUGINS[@]}"; do
    echo "    config = \"plugins/$name/config/config.toml\""
done
