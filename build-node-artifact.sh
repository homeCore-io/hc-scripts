#!/usr/bin/env bash
# build-node-artifact.sh — Build a hermetic runtime-plugin artifact for Node.js.
#
# A runtime plugin is not a binary. For Node it is the plugin's published files
# and every dependency it needs, already installed, plus a manifest, in one
# tarball that a plugin runtime unpacks and runs with no npm and no network:
#
#   plugin.<id>-<version>-node-<abi>.tar.zst
#   ├── plugin.toml      id, version, runtime, abi, arch, entrypoint
#   └── app/             the plugin (as `npm pack` publishes it) and node_modules/
#
# The runtime launches `{interpreter}/node/bin/node app/<entrypoint> <config>`
# on the Node homeCore placed it with (docker/runtime-node/adapter.toml in core).
#
# Pure JavaScript only. A native addon (a `.node` file) is built for one CPU
# and one Node ABI, and refusing them is what lets one artifact run on x86_64
# and aarch64 alike; the registry lists the same file once per architecture.
# Dependencies are installed with `npm ci` from the plugin's own lock, with
# --omit=optional (where native extras usually live) and --ignore-scripts (no
# install script runs, here or anywhere else), so what ships is exactly what
# the lock says.
#
# The plugin's package.json carries what a Cargo.toml's
# [package.metadata.homecore] does:
#
#   "homecore": { "id": "plugin.matter", "name": "Matter",
#                 "category": "Devices", "ui": "ui" }
#
# `entrypoint` there, else `main`, else index.js, is the file the runtime
# runs. Build first (`npm ci && npm run build`); this packs what is there.
#
# Usage:
#   build-node-artifact.sh --plugin <dir> [options]
#
# Options:
#   --plugin        plugin source dir, holding package.json and package-lock.json (required)
#   --node-version  the Node major it is built for, e.g. 24     (default: the node on PATH)
#   --abi           ABI tag for the manifest and the filename   (default: node<major>-glibc_2_28)
#   --out           output directory                            (default: dist/)
#   --keep-build    leave the staging tree for inspection
#   --help
#
# The node and npm on PATH must be that major: npm resolves engines and
# platform-specific packages for the Node it runs on.

set -euo pipefail

PLUGIN_DIR=""
NODE_MAJOR=""
ABI=""
OUT_DIR="dist"
KEEP_BUILD=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin)       PLUGIN_DIR="${2:?}"; shift 2 ;;
    --node-version) NODE_MAJOR="${2:?}"; shift 2 ;;
    --abi)          ABI="${2:?}"; shift 2 ;;
    --out)          OUT_DIR="${2:?}"; shift 2 ;;
    --keep-build)   KEEP_BUILD=1; shift ;;
    --help|-h)      sed -n '2,42p' "$0"; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

[[ -n "$PLUGIN_DIR" ]] || die "--plugin is required"
[[ -f "$PLUGIN_DIR/package.json" ]] || die "$PLUGIN_DIR has no package.json"
[[ -f "$PLUGIN_DIR/package-lock.json" ]] || die "$PLUGIN_DIR has no package-lock.json: \
the artifact installs exactly what a lock says, so commit one (npm install writes it)"
for tool in node npm tar zstd sha256sum; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

HAVE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
: "${NODE_MAJOR:=$HAVE_MAJOR}"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || die "--node-version is a major, such as 24"
[[ "$HAVE_MAJOR" == "$NODE_MAJOR" ]] || die "the node on PATH is $(node -v), and this builds for \
Node $NODE_MAJOR. npm resolves for the Node it runs on, so use that one (actions/setup-node, or nvm)"
: "${ABI:=node${NODE_MAJOR}-glibc_2_28}"
[[ "$ABI" == "node${NODE_MAJOR}-"* ]] || die "--abi $ABI does not name node${NODE_MAJOR}"

PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
BUILD_DIR="$(mktemp -d)"
cleanup() { [[ $KEEP_BUILD -eq 1 ]] && echo "staging kept in $BUILD_DIR" || rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

# ── Manifest source: package.json ───────────────────────────────────────────
mapfile -t META < <(node - "$PLUGIN_DIR/package.json" <<'JS'
const p = require(require("node:path").resolve(process.argv[2]));
const hc = p.homecore || {};
const fail = (m) => { console.error(m); process.exit(1); };
for (const k of ["name", "version"]) if (!p[k]) fail(`package.json is missing \`${k}\``);
if (!hc.id) fail('package.json is missing "homecore": { "id": "plugin.<name>" }');
if (!/^plugin\.[a-z0-9][a-z0-9_-]*$/.test(hc.id)) fail(`homecore.id \`${hc.id}\` must look like plugin.<name>`);
if ((hc.runtime || "node") !== "node") fail(`homecore.runtime is \`${hc.runtime}\`, and this script builds node`);
// The runtime installs nothing: a plugin that uses the SDK without depending on
// it builds and packs clean, then dies at its first require in the runtime.
if (!(p.dependencies || {})["homecore-plugin-sdk"])
  fail('package.json dependencies must include "homecore-plugin-sdk"');
const one = (s) => String(s ?? "").replace(/[\r\n"\\]/g, " ").trim();
console.log(p.name);
console.log(p.version);
console.log(one(p.description));
console.log(hc.id);
console.log(hc.entrypoint || p.main || "index.js");
console.log(one(hc.category));
console.log(one(hc.name) || hc.id);
console.log(hc.ui || "");
JS
) || die "could not read $PLUGIN_DIR/package.json"
[[ ${#META[@]} -ge 7 ]] || die "could not read $PLUGIN_DIR/package.json"
PKG_NAME="${META[0]}"
VERSION="${META[1]}"
DESCRIPTION="${META[2]}"
PLUGIN_ID="${META[3]}"
ENTRYPOINT="${META[4]#./}"
CATEGORY="${META[5]}"
DISPLAY_NAME="${META[6]}"
UI="${META[7]:-}"
[[ "$ENTRYPOINT" != /* && "$ENTRYPOINT" != *..* ]] || die "the entrypoint must be a path inside the package, not $ENTRYPOINT"

note "$PLUGIN_ID $VERSION — Node $NODE_MAJOR ($ABI), $(node -v), npm $(npm -v)"

STAGE="$BUILD_DIR/stage"
APP="$STAGE/app"
mkdir -p "$APP"

# ── 1. The plugin's files, as npm would publish them ────────────────────────
# `files` and .npmignore decide what ships; no lifecycle script runs.
note "packing the plugin's files"
TGZ="$(cd "$PLUGIN_DIR" && npm pack --ignore-scripts --silent --pack-destination "$BUILD_DIR" | tail -1)"
[[ -f "$BUILD_DIR/$TGZ" ]] || die "npm pack produced nothing"
tar -C "$BUILD_DIR" -xzf "$BUILD_DIR/$TGZ"
cp -a "$BUILD_DIR/package/." "$APP/"
cp "$PLUGIN_DIR/package-lock.json" "$APP/package-lock.json"

# ── 2. Dependencies, exactly as locked ──────────────────────────────────────
note "installing dependencies from the lock (no dev, no optional, no scripts)"
(cd "$APP" && npm ci --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund --loglevel=error) \
  || die "npm ci failed: the lock and package.json disagree, or a locked version is gone"

# ── 3. Nothing native ───────────────────────────────────────────────────────
note "checking there is no native code"
NATIVE="$(cd "$APP" && find . \( -name '*.node' -o -name binding.gyp \) -not -path './.git/*' | sort)"
if [[ -n "$NATIVE" ]]; then
  die "native code would tie this artifact to one CPU and Node ABI:
$NATIVE
Drop the dependency, or make it optional so --omit=optional leaves it out."
fi

# ── 4. The SDK and the entrypoint ───────────────────────────────────────────
SDK_JSON="$APP/node_modules/homecore-plugin-sdk/package.json"
[[ -f "$SDK_JSON" ]] || die "homecore-plugin-sdk is declared but was not installed"
SDK_VERSION="$(node -p "require('$SDK_JSON').version")"
[[ -f "$APP/$ENTRYPOINT" ]] || die "the entrypoint $ENTRYPOINT is not in the package (check \"files\", and build first)"
node --check "$APP/$ENTRYPOINT" || die "$ENTRYPOINT does not parse on $(node -v)"
UI_LINE=""
if [[ -n "$UI" ]]; then
  [[ -d "$APP/$UI" ]] || die "homecore.ui names $UI, which is not in the package"
  UI_LINE="ui          = \"app/$UI\""
fi

# ── 5. The manifest ─────────────────────────────────────────────────────────
# `arch = "any"`: the same bytes run on every CPU the Node it names runs on.
cat > "$STAGE/plugin.toml" <<EOF
id          = "$PLUGIN_ID"
name        = "$PKG_NAME"
version     = "$VERSION"
description = "$DESCRIPTION"
runtime     = "node"
abi         = "$ABI"
arch        = "any"
entrypoint  = "$ENTRYPOINT"
sdk_version = "$SDK_VERSION"
$UI_LINE
EOF

# ── 6. Pack ─────────────────────────────────────────────────────────────────
ARTIFACT="$OUT_DIR/${PLUGIN_ID}-${VERSION}-node-${ABI}.tar.zst"
note "packing $(basename "$ARTIFACT")"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
  -C "$STAGE" -cf - plugin.toml app | zstd -19 -T0 -q -o "$ARTIFACT" -f
SHA="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$ARTIFACT")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "artifact=$ARTIFACT"
    echo "sha256=$SHA"
    echo "size=$SIZE"
    echo "plugin_id=$PLUGIN_ID"
    echo "name=$DISPLAY_NAME"
    echo "version=$VERSION"
    echo "abi=$ABI"
    echo "description=$DESCRIPTION"
    echo "category=$CATEGORY"
    echo "sdk_version=$SDK_VERSION"
  } >> "$GITHUB_OUTPUT"
fi
note "wrote $ARTIFACT ($(( SIZE / 1024 )) KB, sha256 $SHA, SDK $SDK_VERSION)"
