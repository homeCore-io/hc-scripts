#!/usr/bin/env bash
# build-archive.sh — Build distributable HomeCore archives.
#
# Three archive kinds:
#   core       homecore/ with core binary + UI + service templates, no plugins
#   plugin     a single-plugin fragment under homecore/plugins/<name>/
#   appliance  homecore/ with everything — core + all plugins merged
#
# Every archive's top-level directory is `homecore/` so users extract
# wherever they want — `tar -xf <archive>` produces a `homecore/` tree.
# Plugin fragments merge into an existing `homecore/` tree with no
# overwrite of unrelated files.
#
# Filenames:
#   homecore-core-<version>-<platform>.tar.gz
#   homecore-appliance-<version>-<platform>.tar.gz
#   <name>-<version>-<platform>.tar.gz
#
# Designed to run identically locally and in GitHub Actions:
#   - Local:  cd into source repo; ./build-archive.sh --kind core
#   - CI:     same call, with --no-build since the build job already produced
#             the binary at the standard cargo path
#
# Usage:
#   build-archive.sh --kind <core|plugin|appliance> [options]
#
# Options:
#   --kind            core | plugin | appliance        (required)
#   --name            plugin crate name (required for --kind plugin)
#   --target          rust target triple, e.g. x86_64-unknown-linux-musl
#                     (default: host)
#   --version         version label baked into filename
#                     (default: auto-detect from Cargo.toml; fallback dev-<sha>)
#   --source          path to source repo (default: $PWD)
#   --bin             path to a prebuilt binary (overrides default cargo path)
#   --ui-dist         path to hc-web-leptos trunk build output (core/appliance)
#   --plugin-fragments-dir
#                     directory containing per-plugin tarballs to merge
#                     into the appliance archive (appliance only)
#   --out             output directory (default: dist/)
#   --build           run cargo build before packaging (default: off)
#   --help

set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────
KIND=""
NAME=""
TARGET=""
VERSION=""
SOURCE="$PWD"
OUT_DIR="dist"
BUILD=false
BIN=""
UI_DIST=""
PLUGIN_FRAGMENTS_DIR=""

usage() { sed -n '2,/^set /p' "$0" | grep -E '^#' | sed 's/^# \?//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)                  KIND="$2"; shift 2 ;;
    --name)                  NAME="$2"; shift 2 ;;
    --target)                TARGET="$2"; shift 2 ;;
    --version)               VERSION="$2"; shift 2 ;;
    --source)                SOURCE="$2"; shift 2 ;;
    --bin)                   BIN="$2"; shift 2 ;;
    --ui-dist)               UI_DIST="$2"; shift 2 ;;
    --plugin-fragments-dir)  PLUGIN_FRAGMENTS_DIR="$2"; shift 2 ;;
    --out)                   OUT_DIR="$2"; shift 2 ;;
    --build)                 BUILD=true; shift ;;
    --help|-h)               usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

# ── Validate ────────────────────────────────────────────────────────
[[ -n "$KIND" ]] || { echo "--kind required" >&2; usage 2; }
case "$KIND" in
  core|plugin|appliance) ;;
  *) echo "--kind must be one of core, plugin, appliance" >&2; usage 2 ;;
esac
[[ "$KIND" = "plugin" && -z "$NAME" ]] && { echo "--kind plugin requires --name" >&2; usage 2; }

# Default target = host
if [[ -z "$TARGET" ]]; then
  case "$(uname -m)-$(uname -s)" in
    x86_64-Linux)   TARGET="x86_64-unknown-linux-musl" ;;
    aarch64-Linux)  TARGET="aarch64-unknown-linux-musl" ;;
    *) echo "no default target for $(uname -m)-$(uname -s); pass --target" >&2; exit 1 ;;
  esac
fi

# Map target → friendly platform label used in filenames
case "$TARGET" in
  x86_64-unknown-linux-musl)  PLATFORM="linux-x86_64" ;;
  aarch64-unknown-linux-musl) PLATFORM="linux-aarch64" ;;
  *)                          PLATFORM="$TARGET" ;;
esac

# Default version: Cargo.toml [package].version → vX.Y.Z, else dev-<sha>
if [[ -z "$VERSION" ]]; then
  v=""
  if [[ -f "$SOURCE/Cargo.toml" ]]; then
    v=$(awk '/^\[package\]/{p=1} p && /^version[[:space:]]*=/{gsub(/.*"/,""); gsub(/".*/,""); print; exit}' "$SOURCE/Cargo.toml" || true)
  fi
  if [[ -n "$v" ]]; then
    VERSION="v$v"
  elif sha=$(git -C "$SOURCE" rev-parse --short HEAD 2>/dev/null); then
    VERSION="dev-$sha"
  else
    VERSION="dev-unknown"
  fi
fi

# Default binary location at the standard cargo path
default_bin() {
  local crate="$1"
  echo "$SOURCE/target/$TARGET/release/$crate"
}

mkdir -p "$OUT_DIR"
log() { echo "==> $*"; }

# Resolve the directory holding this script so we can find bundled
# release/README.<kind>.md.tmpl files alongside it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ─────────────────────────────────────────────────────────
render_readme() {
  # Render a Markdown README into the archive root, substituting
  # {{VERSION}} / {{PLATFORM}} / {{BINARY_NAME}} placeholders.
  #
  # Lookup order:
  #   1. $SOURCE/scripts/release/README.md.tmpl    (per-repo override)
  #   2. $SCRIPT_DIR/release/README.<kind>.md.tmpl (script-bundled default)
  #
  # If neither exists, fall back to copying the source repo's top-level
  # README.md verbatim — preserves backward compatibility for callers
  # that haven't adopted templates yet.
  local kind="$1" dest="$2" binary_name="$3"
  local tmpl=""
  if [[ -f "$SOURCE/scripts/release/README.md.tmpl" ]]; then
    tmpl="$SOURCE/scripts/release/README.md.tmpl"
  elif [[ -f "$SCRIPT_DIR/release/README.${kind}.md.tmpl" ]]; then
    tmpl="$SCRIPT_DIR/release/README.${kind}.md.tmpl"
  fi

  if [[ -n "$tmpl" ]]; then
    sed \
      -e "s|{{VERSION}}|${VERSION}|g" \
      -e "s|{{PLATFORM}}|${PLATFORM}|g" \
      -e "s|{{BINARY_NAME}}|${binary_name}|g" \
      -e "s|{{KIND}}|${kind}|g" \
      "$tmpl" > "$dest/README.md"
  elif [[ -f "$SOURCE/README.md" ]]; then
    cp "$SOURCE/README.md" "$dest/README.md"
  fi
}

copy_root_assets() {
  # Files that go at the root of homecore/ in core and appliance archives.
  local root="$1"
  for f in LICENSE LICENSE-MIT LICENSE-APACHE; do
    [[ -f "$SOURCE/$f" ]] && cp "$SOURCE/$f" "$root/"
  done
}

stage_core() {
  # Stage core's tree under <stage>/homecore. Caller decides whether to
  # tar from there directly (core) or merge plugin fragments first
  # (appliance).
  local stage="$1"
  local root="$stage/homecore"
  mkdir -p "$root/bin" "$root/config" "$root/scripts/service-templates" "$root/plugins"

  local bin_path="${BIN:-$(default_bin homecore)}"
  [[ -f "$bin_path" ]] || { echo "ERROR: binary not found: $bin_path" >&2; exit 1; }
  cp "$bin_path" "$root/bin/homecore"
  chmod 755 "$root/bin/homecore"

  [[ -f "$SOURCE/config/homecore.toml.example" ]] && cp "$SOURCE/config/homecore.toml.example" "$root/config/"
  [[ -d "$SOURCE/config/profiles" ]] && cp -r "$SOURCE/config/profiles" "$root/config/"
  [[ -d "$SOURCE/scripts/service-templates" ]] && \
    cp -r "$SOURCE/scripts/service-templates/." "$root/scripts/service-templates/"

  if [[ -n "$UI_DIST" && -d "$UI_DIST" ]]; then
    mkdir -p "$root/ui/dist"
    cp -r "$UI_DIST/." "$root/ui/dist/"
  fi

  copy_root_assets "$root"
}

write_archive() {
  local stage="$1" archive="$2"
  log "Creating $OUT_DIR/$archive"
  tar -C "$stage" -czf "$OUT_DIR/$archive" homecore
  (cd "$OUT_DIR" && sha256sum "$archive" > "$archive.sha256")
  rm -rf "$stage"
}

# ── Build (optional) ────────────────────────────────────────────────
maybe_build() {
  $BUILD || return 0
  local crate="$1"
  log "cargo build --release --target $TARGET -p $crate (in $SOURCE)"
  ( cd "$SOURCE" && cargo build --release --target "$TARGET" -p "$crate" )
}

# ── Per-kind dispatch ───────────────────────────────────────────────
case "$KIND" in
  core)
    maybe_build homecore
    stage=$(mktemp -d)
    stage_core "$stage"
    render_readme core "$stage/homecore" homecore
    write_archive "$stage" "homecore-core-${VERSION}-${PLATFORM}.tar.gz"
    ;;

  plugin)
    maybe_build "$NAME"
    stage=$(mktemp -d)
    root="$stage/homecore/plugins/$NAME"
    mkdir -p "$root/bin" "$root/config"

    bin_path="${BIN:-$(default_bin "$NAME")}"
    [[ -f "$bin_path" ]] || { echo "ERROR: binary not found: $bin_path" >&2; exit 1; }
    cp "$bin_path" "$root/bin/$NAME"
    chmod 755 "$root/bin/$NAME"
    [[ -f "$SOURCE/config/config.toml.example" ]] && cp "$SOURCE/config/config.toml.example" "$root/config/"

    render_readme plugin "$root" "$NAME"
    write_archive "$stage" "${NAME}-${VERSION}-${PLATFORM}.tar.gz"
    ;;

  appliance)
    # Caller must provide --plugin-fragments-dir with a set of per-plugin
    # tarballs (built via this same script with --kind plugin). We do not
    # attempt to build plugins from source here — appliance assembly is
    # purely a stitch-and-tar step.
    [[ -n "$PLUGIN_FRAGMENTS_DIR" && -d "$PLUGIN_FRAGMENTS_DIR" ]] || \
      { echo "--kind appliance requires --plugin-fragments-dir" >&2; exit 1; }

    maybe_build homecore
    stage=$(mktemp -d)
    stage_core "$stage"

    count=0
    for frag in "$PLUGIN_FRAGMENTS_DIR"/*.tar.gz; do
      [[ -f "$frag" ]] || continue
      log "    merging $(basename "$frag")"
      tar -C "$stage" -xf "$frag"
      count=$((count + 1))
    done
    [[ "$count" -gt 0 ]] || { echo "ERROR: no plugin fragments found in $PLUGIN_FRAGMENTS_DIR" >&2; exit 1; }
    log "merged $count plugin fragments"

    # Render appliance README last so it overrides the core README that
    # stage_core wrote in (plugin fragments don't touch the root README).
    render_readme appliance "$stage/homecore" homecore
    write_archive "$stage" "homecore-appliance-${VERSION}-${PLATFORM}.tar.gz"
    ;;
esac
