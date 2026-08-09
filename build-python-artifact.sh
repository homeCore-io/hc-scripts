#!/usr/bin/env bash
# build-python-artifact.sh — Build a hermetic runtime-plugin artifact for Python.
#
# A runtime plugin is not a binary. It is the plugin, every dependency it needs
# as a wheel, and a manifest, in one tarball that a plugin runtime installs
# offline:
#
#   plugin.<id>-<version>-python-<abi>-<arch>.tar.zst
#   ├── plugin.toml      id, version, runtime, abi, arch, entrypoint, package
#   └── wheelhouse/      every dependency, the SDK, and the plugin itself
#
# Installing it is `pip install --no-index --find-links wheelhouse`. If a wheel
# is missing, that fails here at build time rather than on the operator's
# machine — which is the entire point of building it this way.
#
# Designed to run identically locally and in GitHub Actions, because the two
# traps this script guards against were both found by running it by hand:
#
#   1. `--platform` matches wheel tags EXACTLY. Asking only for
#      manylinux_2_28 does not fail when a package has no such wheel — pip
#      backtracks to some 2022 release that does, and ships it. Measured
#      2026-08-08: jsonschema resolved to 4.17.3 instead of 4.26.0. The fix is
#      a locked, hashed requirement set (nothing to backtrack to) plus the
#      compatible range of tags.
#
#   2. A lock describes an ENVIRONMENT, not a package set. Compiled on the
#      builder's Python, markers evaluate for the builder: `referencing` needs
#      `typing-extensions` only below 3.13, so a lock compiled on 3.14 omits it
#      and the artifact will not install on its cp312 target. The fix is
#      --python-version on the lock step. Both are asserted below, not trusted.
#
# Usage:
#   build-python-artifact.sh --plugin <dir> --sdk <dir> [options]
#
# Options:
#   --plugin          plugin source dir, holding pyproject.toml   (required)
#   --sdk             hc-plugin-sdk-py checkout                   (required)
#   --sdk-version     recorded in plugin.toml (default: from the SDK pyproject)
#   --python-version  target interpreter, e.g. 3.12               (default: 3.12)
#   --abi             ABI tag for the manifest and the filename
#                     (default: cp<pyver>-manylinux_2_28)
#   --arch            x86_64 | aarch64                            (default: x86_64)
#   --out             output directory                            (default: dist/)
#   --keep-build      leave the staging tree for inspection
#   --help
#
# Exit status is non-zero for every failure, including the assertions — a build
# that cannot be trusted must not produce an artifact at all.

set -euo pipefail

PLUGIN_DIR=""
SDK_DIR=""
SDK_VERSION=""
PY_VERSION="3.12"
ABI=""
ARCH="x86_64"
OUT_DIR="dist"
KEEP_BUILD=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin)         PLUGIN_DIR="${2:?}"; shift 2 ;;
    --sdk)            SDK_DIR="${2:?}"; shift 2 ;;
    --sdk-version)    SDK_VERSION="${2:?}"; shift 2 ;;
    --python-version) PY_VERSION="${2:?}"; shift 2 ;;
    --abi)            ABI="${2:?}"; shift 2 ;;
    --arch)           ARCH="${2:?}"; shift 2 ;;
    --out)            OUT_DIR="${2:?}"; shift 2 ;;
    --keep-build)     KEEP_BUILD=1; shift ;;
    --help|-h)        sed -n '2,48p' "$0"; exit 0 ;;
    *)                die "unknown option: $1" ;;
  esac
done

[[ -n "$PLUGIN_DIR" ]] || die "--plugin is required"
[[ -n "$SDK_DIR"    ]] || die "--sdk is required"
[[ -f "$PLUGIN_DIR/pyproject.toml" ]] || die "$PLUGIN_DIR has no pyproject.toml"
[[ -f "$SDK_DIR/pyproject.toml"    ]] || die "$SDK_DIR is not an SDK checkout"

case "$ARCH" in
  x86_64|aarch64) ;;
  *) die "unsupported --arch: $ARCH (x86_64 or aarch64)" ;;
esac

PY_TAG="cp${PY_VERSION//./}"                 # 3.12 → cp312
: "${ABI:=${PY_TAG}-manylinux_2_28}"

command -v uv    >/dev/null || die "uv is required (the lock step needs uv pip compile)"
command -v zstd  >/dev/null || die "zstd is required"

PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
SDK_DIR="$(cd "$SDK_DIR" && pwd)"
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"

BUILD_DIR="$(mktemp -d)"
KEEP_BUILD_TRAP() { [[ $KEEP_BUILD -eq 1 ]] || rm -rf "$BUILD_DIR"; }
trap KEEP_BUILD_TRAP EXIT

# ── Everything runs on the TARGET interpreter ───────────────────────────────
# Not the machine's. uv fetches it if it is not installed, which costs seconds
# and removes a whole class of doubt: environment markers evaluate for the
# interpreter the artifact is built for, by construction rather than by flag.
# The wheels this produces are pure-Python either way; what changes is which
# dependencies the resolver decides are needed.
note "preparing a python $PY_VERSION build environment"
uv venv --python "$PY_VERSION" --seed "$BUILD_DIR/venv" --quiet \
  || die "could not provision python $PY_VERSION — uv could not fetch it"
PYTHON="$BUILD_DIR/venv/bin/python"

# ── Manifest source: pyproject.toml ─────────────────────────────────────────
# [project] carries what [package] carries in a Cargo.toml, and [tool.homecore]
# is the equivalent of [package.metadata.homecore]. Description forwarding to
# the registry comes free — same mechanism as the Rust pipeline, different
# parser.
read_meta() {
  "$PYTHON" - "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
project = doc.get("project", {})
hc = doc.get("tool", {}).get("homecore", {})
missing = [k for k in ("name", "version") if not project.get(k)]
if missing:
    sys.exit(f"pyproject [project] is missing: {', '.join(missing)}")
for key in ("id", "entrypoint"):
    if not hc.get(key):
        sys.exit(f"pyproject [tool.homecore] is missing `{key}`")
runtime = hc.get("runtime", "python")
if runtime != "python":
    sys.exit(f"[tool.homecore] runtime is `{runtime}`, and this script builds python")
print(project["name"])
print(project["version"])
print(project.get("description", ""))
print(hc["id"])
print(hc["entrypoint"])
PY
}

mapfile -t META < <(read_meta "$PLUGIN_DIR/pyproject.toml") \
  || die "could not read $PLUGIN_DIR/pyproject.toml"
[[ ${#META[@]} -ge 5 ]] || die "$(read_meta "$PLUGIN_DIR/pyproject.toml" 2>&1)"
PKG_NAME="${META[0]}"
VERSION="${META[1]}"
DESCRIPTION="${META[2]}"
PLUGIN_ID="${META[3]}"
ENTRYPOINT="${META[4]}"

if [[ -z "$SDK_VERSION" ]]; then
  SDK_VERSION="$("$PYTHON" - "$SDK_DIR/pyproject.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f)["project"]["version"])
PY
)"
fi

note "$PLUGIN_ID $VERSION — python $PY_VERSION ($ABI) on $ARCH, SDK $SDK_VERSION"

STAGE="$BUILD_DIR/stage"
WHEELHOUSE="$STAGE/wheelhouse"
mkdir -p "$WHEELHOUSE"

# ── 1. The SDK and the plugin, built from source ────────────────────────────
# The SDK is published to no index, deliberately, so it cannot be downloaded —
# it is built from a pinned checkout into the wheelhouse alongside everything
# else. That is what bakes an explicit SDK version into each artifact.
note "building the SDK wheel from $SDK_DIR"
"$PYTHON" -m pip wheel --no-deps --wheel-dir "$WHEELHOUSE" "$SDK_DIR" -q \
  || die "building the SDK wheel failed"

note "building the plugin wheel"
"$PYTHON" -m pip wheel --no-deps --wheel-dir "$WHEELHOUSE" "$PLUGIN_DIR" -q \
  || die "building the plugin wheel failed"

# ── 2. Lock, once, for the TARGET interpreter ───────────────────────────────
# Not the builder's. See trap 2 at the top of this file.
LOCK="$BUILD_DIR/requirements.lock"
note "locking dependencies for python $PY_VERSION"
# The SDK's requirements and the plugin's, resolved together so the two cannot
# disagree about a shared dependency at install time. The SDK itself is excluded
# — it is on no index, and it is already in the wheelhouse, built from the pinned
# checkout above. Feeding the project directories to the resolver instead would
# put unhashable local paths in a lock that is about to be used with
# --require-hashes.
"$PYTHON" - "$SDK_DIR/pyproject.toml" "$PLUGIN_DIR/pyproject.toml" \
  > "$BUILD_DIR/requirements.in" <<'PY'
import re, sys, tomllib

SDK_DIST = "homecore-plugin-sdk"

def normalise(name):
    return re.sub(r"[-_.]+", "-", name).lower()

seen = []
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        for dep in tomllib.load(f).get("project", {}).get("dependencies", []):
            name = re.split(r"[<>=!~\[; ]", dep.strip(), 1)[0]
            if normalise(name) == SDK_DIST:
                continue
            if dep not in seen:
                seen.append(dep)
print("\n".join(seen))
PY

uv pip compile "$BUILD_DIR/requirements.in" \
  --python-version "$PY_VERSION" \
  --generate-hashes \
  --quiet \
  --output-file "$LOCK" \
  || die "locking failed — resolve it for python $PY_VERSION before shipping"

# Assertion for trap 2, checked rather than trusted. uv records its own
# invocation at the top of the lock, so this catches the flag being dropped —
# by an edit here, or by a future uv that stops honouring it.
grep -q -- "--python-version $PY_VERSION" "$LOCK" \
  || die "the lock does not record --python-version $PY_VERSION. A lock describes an \
environment, not a package set: resolved for the wrong interpreter it silently omits \
dependencies whose markers exclude it, and the artifact fails to install on the target."

# ── 3. Download against the lock, never resolving again ─────────────────────
# Three platform tags, because --platform matches exactly and a manylinux_2_17
# wheel does not satisfy a manylinux_2_28 request. --require-hashes is what
# makes a missing wheel loud: with versions pinned there is nothing to
# backtrack to. See trap 1.
note "downloading wheels for manylinux/$ARCH"
"$PYTHON" -m pip download \
  --only-binary=:all: \
  --implementation cp \
  --require-hashes \
  --python-version "$PY_VERSION" \
  --platform "manylinux_2_28_${ARCH}" \
  --platform "manylinux_2_17_${ARCH}" \
  --platform "manylinux2014_${ARCH}" \
  --platform "any" \
  -r "$LOCK" -d "$WHEELHOUSE" -q \
  || die "no wheel for one of the locked versions on $ARCH — that dependency does not \
support this architecture yet, which is a fact worth knowing rather than working around"

# ── 4. Every locked package must be present ─────────────────────────────────
# Belt and braces over pip's exit status: a wheelhouse that is missing something
# fails at install time on the operator's machine, and the build is the last
# place that failure is cheap.
note "checking the wheelhouse is complete"
"$PYTHON" - "$LOCK" "$WHEELHOUSE" <<'PY' || exit 1
import pathlib, re, sys

lock, wheelhouse = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def normalise(name: str) -> str:
    return re.sub(r"[-_.]+", "_", name).lower()

wanted = set()
for line in lock.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith(("#", "-", "\\")) or "==" not in line:
        continue
    wanted.add(normalise(line.split("==", 1)[0].split("[", 1)[0].strip()))

have = {normalise(p.name.split("-", 1)[0]) for p in wheelhouse.glob("*.whl")}
missing = sorted(wanted - have)
if missing:
    sys.exit(
        f"the wheelhouse is missing {len(missing)} locked package(s): {', '.join(missing)}"
    )
print(f"    {len(list(wheelhouse.glob('*.whl')))} wheels, all {len(wanted)} locked packages present")
PY

# ── 5. The manifest ─────────────────────────────────────────────────────────
# `package` is what the runtime resolves {plugin_wheel} from; `entrypoint` is
# what its adapter's launch template means by one.
cat > "$STAGE/plugin.toml" <<EOF
id          = "$PLUGIN_ID"
name        = "$PKG_NAME"
version     = "$VERSION"
description = "$DESCRIPTION"
runtime     = "python"
abi         = "$ABI"
arch        = "$ARCH"
entrypoint  = "$ENTRYPOINT"
package     = "$PKG_NAME"
sdk_version = "$SDK_VERSION"
EOF

# The lock ships inside the artifact. It is the only record of exactly what was
# resolved, and an operator asking "which version of X is this running" should
# not have to find the build that produced it.
cp "$LOCK" "$STAGE/requirements.lock"

# ── 6. Pack ─────────────────────────────────────────────────────────────────
ARTIFACT="$OUT_DIR/${PLUGIN_ID}-${VERSION}-python-${ABI}-${ARCH}.tar.zst"
note "packing $(basename "$ARTIFACT")"
tar -C "$STAGE" --zstd -cf "$ARTIFACT" plugin.toml requirements.lock wheelhouse

SHA="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$ARTIFACT")"

# Consumed by the release workflow, which needs them for the registry entry.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "artifact=$ARTIFACT"
    echo "sha256=$SHA"
    echo "size=$SIZE"
    echo "plugin_id=$PLUGIN_ID"
    echo "version=$VERSION"
    echo "abi=$ABI"
    echo "description=$DESCRIPTION"
  } >> "$GITHUB_OUTPUT"
fi

printf '\n%s\n  sha256 %s\n  %s bytes\n' "$ARTIFACT" "$SHA" "$SIZE"
