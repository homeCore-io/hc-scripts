#!/usr/bin/env bash
# deploy.sh: build HomeCore from a workspace checkout and install it to a
# prod-like local directory, for smoke-testing an install before a release.
#
# DESTINATION LAYOUT
# ==================
#   $DEST/
#     bin/
#       homecore                       main binary
#     config/
#       homecore.toml                  main config (preserved; --force-config to overwrite)
#       profiles/                      ecosystem profiles (all files, recursively)
#     rules/                           automation rule RON files
#     data/                            state.redb, history.db  (runtime, not deployed)
#     logs/                            homecore rolling logs    (runtime, not deployed)
#     scripts/
#       service-templates/             systemd / launchd unit templates
#     plugins/
#       hc-yolink/
#         bin/hc-yolink                plugin binary
#         config/config.toml           plugin config (preserved; --force-config to overwrite)
#         logs/                        plugin logs land here automatically
#       hc-hue/  hc-zwave/  ...        (same structure, one per plugin)
#     web/                             hc-web-svelte, the web app and its UI server
#       build/  server/  package.json  (replaced on each deploy)
#       data/                          the UI server's documents (HC_DATA_DIR, kept)
#
# Plugin log dirs are derived by the plugin from its config path
# (<config dir>/../logs), so a config at plugins/<name>/config/config.toml
# logs to plugins/<name>/logs/ with no extra wiring.
#
# WHERE THINGS COME FROM
# ======================
#   homecore and every Rust plugin are members of core's cargo workspace
#   (core/Cargo.toml). They are built there in one cargo invocation and their
#   binaries come from core/target/<release|debug>/. The plugin list is read
#   from the workspace members, so a new plugin needs no change here.
#   hc-captest and hc-plugin-template are members too but are left out.
#
#   The web app is clients/hc-web-svelte. It is a Node server (the app plus
#   the UI server that proxies /api/v1 to core), not a static bundle core
#   serves, so it is built with npm and installed under $DEST/web/. You start
#   it yourself with node; the summary prints the command. The usual way to
#   run it beside core is its container (ghcr.io/homecore-io/hc-web-svelte,
#   see the docker repo), and this component is optional.
#
# USAGE
# =====
#   ./deploy.sh [OPTIONS] [COMPONENT...]
#
# COMPONENTS
#   homecore        Main HomeCore server
#   hc-web-svelte   The web app and its UI server (needs node and npm)
#   hc-<name>       A Rust plugin from core/plugins/ (--list prints them)
#
# OPTIONS
#   --all           Build and install all components (default when none specified)
#   --no-build      Skip building; install what is already built
#   --sync-config   Copy configs from source (skips files that already exist)
#   --force-config  Overwrite configs from source even if they already exist
#   --dest DIR      Installation directory (default: /var/tmp/homeCore)
#   --debug         Build debug instead of release
#   --dry-run       Check sources and print what would be built and installed
#   --list          Print the components and exit
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
DRY_RUN=false
RELEASE_FLAG="--release"
RELEASE_DIR="release"
COMPONENTS=()

# ---------------------------------------------------------------------------
# Source paths
# ---------------------------------------------------------------------------

HOMECORE_SRC="$WORKSPACE_ROOT/core"
PLUGINS_SRC="$HOMECORE_SRC/plugins"
WEB_SRC="$WORKSPACE_ROOT/clients/hc-web-svelte"
WEB_COMPONENT="hc-web-svelte"

# Workspace members that are not plugins anyone deploys.
EXCLUDED_PLUGINS="hc-captest hc-plugin-template"

# ===========================================================================
# PLUGIN LIST, from core/Cargo.toml's [workspace] members
# ===========================================================================
#
# Each plugin is deployed to:
#   $DEST/plugins/<name>/bin/<name>
#   $DEST/plugins/<name>/config/config.toml  (from source config/config.toml,
#                                             or config.toml.example)
#   $DEST/plugins/<name>/logs/               (empty; logs land here at runtime)

PLUGINS=()
if [[ -f "$HOMECORE_SRC/Cargo.toml" ]]; then
    while IFS= read -r name; do
        [[ " $EXCLUDED_PLUGINS " == *" $name "* ]] && continue
        PLUGINS+=("$name")
    done < <(
        sed -n '/^\[workspace\]/,/^\]/p' "$HOMECORE_SRC/Cargo.toml" \
            | grep -o '"plugins/hc-[^"]*"' \
            | tr -d '"' \
            | sed 's#^plugins/##'
    )
fi

ALL_COMPONENTS=(homecore "$WEB_COMPONENT" "${PLUGINS[@]}")

# ===========================================================================
# ARGUMENT PARSING
# ===========================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          COMPONENTS=("${ALL_COMPONENTS[@]}"); shift ;;
        --no-build)     BUILD=false; shift ;;
        --sync-config)  SYNC_CONFIG=true; shift ;;
        --force-config) FORCE_CONFIG=true; SYNC_CONFIG=true; shift ;;
        --dest)
            [[ $# -ge 2 ]] || { echo "ERROR: --dest needs a directory" >&2; exit 1; }
            DEST="$2"; shift 2 ;;
        --debug)        RELEASE_FLAG=""; RELEASE_DIR="debug"; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --list)
            if [[ ${#PLUGINS[@]} -eq 0 ]]; then
                echo "ERROR: no plugins found in $HOMECORE_SRC/Cargo.toml" >&2
                exit 1
            fi
            printf '%s\n' "${ALL_COMPONENTS[@]}"
            exit 0
            ;;
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

is_plugin() {
    local comp="$1"
    [[ "$comp" != "homecore" && "$comp" != "$WEB_COMPONENT" ]]
}

# Return 0 if a component's source directory exists and is buildable
check_source() {
    local comp="$1"
    if [[ "$comp" == "homecore" ]]; then
        [[ -f "$HOMECORE_SRC/Cargo.toml" ]]
    elif [[ "$comp" == "$WEB_COMPONENT" ]]; then
        [[ -f "$WEB_SRC/package.json" ]]
    else
        [[ -f "$PLUGINS_SRC/$comp/Cargo.toml" ]]
    fi
}

source_path() {
    local comp="$1"
    if [[ "$comp" == "homecore" ]]; then
        echo "$HOMECORE_SRC"
    elif [[ "$comp" == "$WEB_COMPONENT" ]]; then
        echo "$WEB_SRC"
    else
        echo "$PLUGINS_SRC/$comp"
    fi
}

# Every binary, core's and the plugins', lands in core's workspace target dir.
binary_src_path() {
    local comp="$1"
    echo "$HOMECORE_SRC/target/$RELEASE_DIR/$comp"
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

    local existed=false
    [[ -e "$dst" ]] && existed=true
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    if $existed; then
        info "[updated] $label"
    else
        info "[created] $label"
    fi
}

# ===========================================================================
# SCAFFOLD: create the destination directory tree (idempotent)
# ===========================================================================

scaffold_homecore() {
    log "Scaffolding homecore dirs under $DEST"
    mkdir -p "$DEST/bin"
    mkdir -p "$DEST/config/profiles"
    mkdir -p "$DEST/rules"
    mkdir -p "$DEST/data"
    mkdir -p "$DEST/logs"
    mkdir -p "$DEST/scripts/service-templates"
    info "bin/  config/  rules/  data/  logs/  scripts/"

    # Copy scripts unconditionally; these are not credentials-bearing config files
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
        info "[created] config/homecore.toml  (from .example; update credentials before running)"
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

scaffold_web() {
    log "Scaffolding web app dirs: web/"
    mkdir -p "$DEST/web/data"
    info "web/  web/data/"
}

# ===========================================================================
# BUILD
# ===========================================================================

# homecore and the plugins share one workspace, so build them in one cargo
# run: shared dependencies compile once.
cargo_packages() {
    local comp
    for comp in "${COMPONENTS[@]}"; do
        [[ "$comp" == "$WEB_COMPONENT" ]] && continue
        printf -- '-p %s ' "$comp"
    done
}

build_rust() {
    local pkgs
    pkgs="$(cargo_packages)"
    [[ -z "$pkgs" ]] && return 0
    log "Building in core's workspace ($RELEASE_DIR): ${pkgs//-p /}"
    # shellcheck disable=SC2086  # RELEASE_FLAG and pkgs are word lists on purpose
    cargo build $RELEASE_FLAG --manifest-path "$HOMECORE_SRC/Cargo.toml" $pkgs
}

build_web() {
    log "Building $WEB_COMPONENT (npm ci, npm run build)"
    (cd "$WEB_SRC" && npm ci && npm run build)
}

# ===========================================================================
# INSTALL
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

# The same files the app's Dockerfile puts in its image: build/ holds the app
# with every package bundled in, server/ is the UI server. No node_modules.
install_web() {
    if [[ ! -d "$WEB_SRC/build" ]]; then
        echo "ERROR: $WEB_COMPONENT build not found: $WEB_SRC/build" >&2
        echo "       Run without --no-build, or run 'npm run build' there first." >&2
        return 1
    fi

    rm -rf "$DEST/web/build" "$DEST/web/server"
    cp -r "$WEB_SRC/build" "$DEST/web/build"
    cp -r "$WEB_SRC/server" "$DEST/web/server"
    cp "$WEB_SRC/package.json" "$DEST/web/package.json"
    ok "web/build/  web/server/  web/package.json  ($(find "$DEST/web/build" -type f | wc -l) files in build/)"
}

# ===========================================================================
# SYNC CONFIGS  (--sync-config / --force-config)
# ===========================================================================

sync_homecore_config() {
    log "Syncing homecore config from source"

    # Main config (only if the real homecore.toml exists in source)
    local cfg="$HOMECORE_SRC/config/homecore.toml"
    [[ -f "$cfg" ]] && sync_file "$cfg" "$DEST/config/homecore.toml"

    # All ecosystem profiles, one recursive pass
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
    local src_dir="$PLUGINS_SRC/$name"

    # Prefer the real config; fall back to the example if not yet created
    local src="$src_dir/config/config.toml"
    if [[ ! -f "$src" ]]; then
        src="$src_dir/config/config.toml.example"
        if [[ ! -f "$src" ]]; then
            warn "$name: no config/config.toml or config/config.toml.example found; skipping"
            return
        fi
        warn "$name: config/config.toml not found; deploying .example (rename and fill in credentials)"
    fi

    sync_file "$src" "$DEST/plugins/$name/config/config.toml"
}

# ===========================================================================
# MAIN
# ===========================================================================

if [[ ${#PLUGINS[@]} -eq 0 ]]; then
    echo "ERROR: no plugins found in $HOMECORE_SRC/Cargo.toml (is core cloned?)" >&2
    exit 1
fi

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
$DRY_RUN && info "Dry run    : nothing is built or installed"
echo

# ---------------------------------------------------------------------------
# Pre-flight: verify all requested sources (and tools) exist before any work
# ---------------------------------------------------------------------------
log "Checking source directories"
WANT_WEB=false
WANT_RUST=false
for comp in "${COMPONENTS[@]}"; do
    if ! check_source "$comp"; then
        echo "ERROR: $comp source not found at $(source_path "$comp")" >&2
        exit 1
    fi
    if [[ "$comp" == "$WEB_COMPONENT" ]]; then WANT_WEB=true; else WANT_RUST=true; fi
    info "found: $comp"
done
if $BUILD; then
    if $WANT_RUST && ! command -v cargo >/dev/null 2>&1; then
        echo "ERROR: cargo not found on PATH" >&2; exit 1
    fi
    if $WANT_WEB && ! command -v npm >/dev/null 2>&1; then
        echo "ERROR: npm not found on PATH (needed for $WEB_COMPONENT; leave it out to skip)" >&2
        exit 1
    fi
fi
echo

if $DRY_RUN; then
    log "Would run"
    if $BUILD; then
        pkgs="$(cargo_packages)"
        [[ -n "$pkgs" ]] && info "cargo build $RELEASE_FLAG --manifest-path $HOMECORE_SRC/Cargo.toml $pkgs"
        $WANT_WEB && info "(cd $WEB_SRC && npm ci && npm run build)"
    fi
    log "Would install"
    for comp in "${COMPONENTS[@]}"; do
        if [[ "$comp" == "homecore" ]]; then
            info "$(binary_src_path homecore) -> $DEST/bin/homecore"
        elif [[ "$comp" == "$WEB_COMPONENT" ]]; then
            info "$WEB_SRC/{build,server,package.json} -> $DEST/web/"
        else
            info "$(binary_src_path "$comp") -> $DEST/plugins/$comp/bin/$comp"
        fi
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if $BUILD; then
    $WANT_RUST && { build_rust; echo; }
    $WANT_WEB && { build_web; echo; }
fi

# ---------------------------------------------------------------------------
# Scaffold destination directories
# ---------------------------------------------------------------------------
for comp in "${COMPONENTS[@]}"; do
    if [[ "$comp" == "homecore" ]]; then
        scaffold_homecore
    elif [[ "$comp" == "$WEB_COMPONENT" ]]; then
        scaffold_web
    else
        scaffold_plugin "$comp"
    fi
done
echo

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
log "Installing"
for comp in "${COMPONENTS[@]}"; do
    if [[ "$comp" == "homecore" ]]; then
        install_homecore_binary
    elif [[ "$comp" == "$WEB_COMPONENT" ]]; then
        install_web
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
        elif [[ "$comp" == "$WEB_COMPONENT" ]]; then
            : # the web app takes its settings from the environment
        else
            sync_plugin_config "$comp"
        fi
        echo
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "Deploy complete: $DEST"
echo

if [[ " ${COMPONENTS[*]} " == *" homecore "* && ! -f "$DEST/config/homecore.toml" ]]; then
    echo "  NOTE: $DEST/config/homecore.toml does not exist."
    echo "        Run with --sync-config to copy from source, or create manually."
    echo
fi

if $WANT_WEB; then
    echo "  Start the web app (it proxies /api/v1 to core at HC_CORE_URL):"
    echo "    HC_CORE_URL=http://127.0.0.1:8080 HC_DATA_DIR=$DEST/web/data PORT=3001 \\"
    echo "      BODY_SIZE_LIMIT=Infinity node $DEST/web/server/index.js"
    echo
fi

DEPLOYED_PLUGINS=()
for comp in "${COMPONENTS[@]}"; do
    is_plugin "$comp" && DEPLOYED_PLUGINS+=("$comp")
done
if [[ ${#DEPLOYED_PLUGINS[@]} -gt 0 ]]; then
    echo "  Core installs plugins from the registry, not from these paths. To have"
    echo "  core supervise a plugin you built here, add to homecore.toml:"
    for name in "${DEPLOYED_PLUGINS[@]}"; do
        echo
        echo "    [[plugins]]"
        echo "    id      = \"plugin.${name#hc-}\""
        echo "    binary  = \"plugins/$name/bin/$name\""
        echo "    config  = \"plugins/$name/config/config.toml\""
        echo "    enabled = true"
    done
    echo
fi
