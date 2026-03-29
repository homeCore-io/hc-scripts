#!/usr/bin/env bash
# release-local.sh — Build and package a homeCore component for local testing.
#
# Run from the component's repo directory:
#   /path/to/hc-scripts/release-local.sh [OPTIONS]
#
# Options:
#   --binary   NAME      Binary name (default: auto-detected from Cargo.toml [[bin]])
#   --version  VER       Version string (default: auto-detected from Cargo.toml [package])
#   --target   TRIPLE    Rust target triple (default: x86_64-unknown-linux-musl)
#   --extra    SRC:DST   Extra file or directory to include in the archive.
#                        SRC is relative to the repo root; DST is the path inside the archive.
#                        May be specified multiple times.
#   --out      DIR       Output directory for the archive (default: ./dist)
#   --help
#
# Examples:
#   # Plugin — auto-detect binary and version, default x86_64 musl target:
#   ../../hc-scripts/release-local.sh
#
#   # Core — include extra files:
#   ../../hc-scripts/release-local.sh \
#     --extra config/profiles:config/profiles \
#     --extra rules/examples:rules/examples \
#     --extra scripts/service-templates:scripts/service-templates
#
#   # aarch64 via cross:
#   ../../hc-scripts/release-local.sh --target aarch64-unknown-linux-musl
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
BINARY=""
VERSION=""
TARGET="x86_64-unknown-linux-musl"
OUT_DIR="dist"
EXTRA_PAIRS=()   # "src:dst" strings

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)   BINARY="$2";   shift 2 ;;
        --version)  VERSION="$2";  shift 2 ;;
        --target)   TARGET="$2";   shift 2 ;;
        --out)      OUT_DIR="$2";  shift 2 ;;
        --extra)    EXTRA_PAIRS+=("$2"); shift 2 ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Auto-detect binary name and version from Cargo.toml
# -----------------------------------------------------------------------------
CARGO_TOML="Cargo.toml"

if [[ ! -f "$CARGO_TOML" ]]; then
    echo "ERROR: No Cargo.toml found in $(pwd)" >&2
    echo "       Run this script from a component repo directory." >&2
    exit 1
fi

if [[ -z "$BINARY" ]]; then
    # [[bin]] name = "..." — take the first one
    BINARY=$(awk '
        /^\[\[bin\]\]/ { in_bin=1 }
        in_bin && /^name[[:space:]]*=/ {
            gsub(/.*=[[:space:]]*"/, ""); gsub(/".*/, ""); print; exit
        }
    ' "$CARGO_TOML")

    if [[ -z "$BINARY" ]]; then
        # Fall back to [package] name
        BINARY=$(awk '
            /^\[package\]/ { in_pkg=1 }
            in_pkg && /^name[[:space:]]*=/ {
                gsub(/.*=[[:space:]]*"/, ""); gsub(/".*/, ""); print; exit
            }
        ' "$CARGO_TOML")
    fi
fi

if [[ -z "$BINARY" ]]; then
    echo "ERROR: Could not detect binary name. Pass --binary NAME." >&2
    exit 1
fi

if [[ -z "$VERSION" ]]; then
    VERSION=$(awk '
        /^\[package\]/ { in_pkg=1 }
        in_pkg && /^version[[:space:]]*=/ {
            gsub(/.*=[[:space:]]*"/, ""); gsub(/".*/, ""); print; exit
        }
    ' "$CARGO_TOML")
fi

if [[ -z "$VERSION" ]]; then
    echo "ERROR: Could not detect version. Pass --version VER." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Derive platform label from target triple
# -----------------------------------------------------------------------------
case "$TARGET" in
    x86_64-unknown-linux-musl)  PLATFORM="linux-x86_64" ;;
    aarch64-unknown-linux-musl) PLATFORM="linux-aarch64" ;;
    *)                          PLATFORM="$TARGET" ;;
esac

ARCHIVE_NAME="${BINARY}-v${VERSION}-${PLATFORM}"

# -----------------------------------------------------------------------------
# Print plan
# -----------------------------------------------------------------------------
echo "========================================"
echo " homeCore local release builder"
echo "========================================"
echo "  binary   : $BINARY"
echo "  version  : $VERSION"
echo "  target   : $TARGET ($PLATFORM)"
echo "  archive  : ${ARCHIVE_NAME}.tar.gz"
echo "  output   : $OUT_DIR/"
echo "========================================"
echo ""

# -----------------------------------------------------------------------------
# Ensure musl target is installed
# -----------------------------------------------------------------------------
if ! rustup target list --installed | grep -q "$TARGET"; then
    echo ">> Installing Rust target $TARGET..."
    rustup target add "$TARGET"
fi

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
HOST_ARCH=$(uname -m)

if [[ "$TARGET" == aarch64-* && "$HOST_ARCH" != "aarch64" ]]; then
    # Cross-compile via 'cross'
    if ! command -v cross &>/dev/null; then
        echo "ERROR: 'cross' is required for aarch64 builds." >&2
        echo "       Install with: cargo install cross" >&2
        exit 1
    fi
    echo ">> Building with cross (aarch64 cross-compile)..."
    cross build --release --target "$TARGET"
else
    echo ">> Building with cargo..."
    cargo build --release --target "$TARGET"
fi

BUILT_BINARY="target/${TARGET}/release/${BINARY}"

if [[ ! -f "$BUILT_BINARY" ]]; then
    echo "ERROR: Expected binary not found at $BUILT_BINARY" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Assemble archive directory
# -----------------------------------------------------------------------------
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

ARCHIVE_ROOT="${STAGE_DIR}/${ARCHIVE_NAME}"
mkdir -p "${ARCHIVE_ROOT}/bin"

echo ">> Assembling archive..."

# Binary
cp "$BUILT_BINARY" "${ARCHIVE_ROOT}/bin/${BINARY}"
chmod 755 "${ARCHIVE_ROOT}/bin/${BINARY}"
echo "   bin/${BINARY}"

# Auto-include standard config examples if they exist
for cfg in \
    "config/homecore.toml.example:config/homecore.toml.example" \
    "config/config.toml.example:config/config.toml.example"
do
    src="${cfg%%:*}"
    dst="${cfg##*:}"
    if [[ -f "$src" ]]; then
        mkdir -p "${ARCHIVE_ROOT}/$(dirname "$dst")"
        cp "$src" "${ARCHIVE_ROOT}/${dst}"
        echo "   $dst"
    fi
done

# README
if [[ -f "README.md" ]]; then
    cp README.md "${ARCHIVE_ROOT}/README.md"
    echo "   README.md"
fi

# Extra files/dirs specified via --extra src:dst
for pair in "${EXTRA_PAIRS[@]}"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if [[ ! -e "$src" ]]; then
        echo "WARNING: extra path not found, skipping: $src" >&2
        continue
    fi
    mkdir -p "${ARCHIVE_ROOT}/$(dirname "$dst")"
    if [[ -d "$src" ]]; then
        cp -r "$src" "${ARCHIVE_ROOT}/${dst}"
        echo "   ${dst}/"
    else
        cp "$src" "${ARCHIVE_ROOT}/${dst}"
        echo "   $dst"
    fi
done

# -----------------------------------------------------------------------------
# Create archive and checksum
# -----------------------------------------------------------------------------
mkdir -p "$OUT_DIR"

echo ""
echo ">> Creating archive..."
tar -czf "${OUT_DIR}/${ARCHIVE_NAME}.tar.gz" -C "$STAGE_DIR" "$ARCHIVE_NAME"

echo ">> Creating checksum..."
(cd "$OUT_DIR" && sha256sum "${ARCHIVE_NAME}.tar.gz" > "${ARCHIVE_NAME}.tar.gz.sha256")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
ARCHIVE_SIZE=$(du -sh "${OUT_DIR}/${ARCHIVE_NAME}.tar.gz" | cut -f1)

echo ""
echo "========================================"
echo " Done"
echo "========================================"
echo "  ${OUT_DIR}/${ARCHIVE_NAME}.tar.gz  ($ARCHIVE_SIZE)"
echo "  ${OUT_DIR}/${ARCHIVE_NAME}.tar.gz.sha256"
echo ""
echo " Verify:"
echo "  tar -tzf ${OUT_DIR}/${ARCHIVE_NAME}.tar.gz"
echo ""
echo " Extract and run:"
echo "  tar -xzf ${OUT_DIR}/${ARCHIVE_NAME}.tar.gz"
echo "  HOMECORE_HOME=\$(pwd)/${ARCHIVE_NAME} ${ARCHIVE_NAME}/bin/${BINARY}"
echo "========================================"
