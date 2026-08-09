#!/usr/bin/env bash
# smoke-python-artifact.sh — Prove a built artifact actually runs.
#
# A green build is not a shipped plugin. For a Rust plugin "it compiled" is at
# least a signal; here it does not exist as one, so the release pipeline has to
# install the artifact the way an operator's runtime will and watch it work:
#
#   1. unpack the tarball
#   2. `pip install --no-index --find-links wheelhouse` into a fresh venv,
#      offline, so a missing wheel fails here rather than in someone's house
#   3. launch the plugin against a scratch broker
#   4. wait for it to register on homecore/plugins/<id>/register
#
# Step 4 is the one that matters. Installing proves the wheelhouse is complete;
# only registering proves the SDK imported, the compiled extensions loaded for
# this architecture, and the plugin got far enough to say hello.
#
# Usage:
#   smoke-python-artifact.sh --artifact <file.tar.zst> [options]
#
# Options:
#   --artifact        the .tar.zst to test                        (required)
#   --broker-host     MQTT broker                          (default: 127.0.0.1)
#   --broker-port     MQTT port                                  (default: 1883)
#   --timeout         seconds to wait for registration             (default: 45)
#   --python-version  interpreter for the test venv               (default: 3.12)
#   --help
#
# Runs only where the artifact's architecture matches the machine. An aarch64
# artifact on an x86_64 runner ships built and resolved but NOT executed, and
# the release notes should say so rather than implying parity.

set -euo pipefail

ARTIFACT=""
BROKER_HOST="127.0.0.1"
BROKER_PORT="1883"
TIMEOUT=45
PY_VERSION="3.12"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact)       ARTIFACT="${2:?}"; shift 2 ;;
    --broker-host)    BROKER_HOST="${2:?}"; shift 2 ;;
    --broker-port)    BROKER_PORT="${2:?}"; shift 2 ;;
    --timeout)        TIMEOUT="${2:?}"; shift 2 ;;
    --python-version) PY_VERSION="${2:?}"; shift 2 ;;
    --help|-h)        sed -n '2,32p' "$0"; exit 0 ;;
    *)                die "unknown option: $1" ;;
  esac
done

[[ -f "$ARTIFACT" ]] || die "--artifact is required and must exist"
command -v uv >/dev/null || die "uv is required"
ARTIFACT="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"

WORK="$(mktemp -d)"
trap 'kill "${PLUGIN_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

note "unpacking $(basename "$ARTIFACT")"
tar -C "$WORK" --zstd -xf "$ARTIFACT"
[[ -f "$WORK/plugin.toml" ]] || die "no plugin.toml at the artifact root"

read_manifest() {
  "$1" - "$WORK/plugin.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    m = tomllib.load(f)
print(m["id"]); print(m["package"]); print(m["entrypoint"]); print(m.get("arch", ""))
PY
}

note "creating a clean python $PY_VERSION environment"
uv venv --python "$PY_VERSION" --seed "$WORK/venv" --quiet || die "could not provision python $PY_VERSION"
VENV_PY="$WORK/venv/bin/python"

mapfile -t M < <(read_manifest "$VENV_PY")
PLUGIN_ID="${M[0]}"; PACKAGE="${M[1]}"; ENTRYPOINT="${M[2]}"; ARTIFACT_ARCH="${M[3]}"

HOST_ARCH="$(uname -m)"
if [[ -n "$ARTIFACT_ARCH" && "$ARTIFACT_ARCH" != "$HOST_ARCH" ]]; then
  note "SKIPPED: this artifact is $ARTIFACT_ARCH and the runner is $HOST_ARCH."
  note "It ships built and resolved, but NOT executed. Say so in the release notes."
  exit 0
fi

# Offline by construction: --no-index means a wheel that is not in the tarball
# cannot be fetched from anywhere, which is exactly the operator's situation.
note "installing offline from the wheelhouse"
"$VENV_PY" -m pip install --no-index --find-links "$WORK/wheelhouse" "$PACKAGE" -q \
  || die "the artifact does not install from its own wheelhouse"

# The plugin's config, in the shape core seeds: every plugin, in every language,
# reads its config from argv[1].
cat > "$WORK/config.toml" <<EOF
[homecore]
broker_host = "$BROKER_HOST"
broker_port = $BROKER_PORT
plugin_id = "$PLUGIN_ID"
password = "smoke"
EOF

note "watching for $PLUGIN_ID to register"
"$VENV_PY" - "$BROKER_HOST" "$BROKER_PORT" "$PLUGIN_ID" "$TIMEOUT" > "$WORK/watch.log" 2>&1 <<'PY' &
import sys, threading
import paho.mqtt.client as mqtt

host, port, plugin_id, timeout = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
seen = threading.Event()

def on_message(client, _userdata, msg):
    print(f"saw {msg.topic}", flush=True)
    seen.set()

c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
c.on_message = on_message
c.connect(host, port, 30)
c.subscribe(f"homecore/plugins/{plugin_id}/register", qos=1)
c.loop_start()
sys.exit(0 if seen.wait(timeout) else 1)
PY
WATCHER_PID=$!
sleep 2

note "launching the plugin"
"$VENV_PY" -m "$ENTRYPOINT" "$WORK/config.toml" > "$WORK/plugin.log" 2>&1 &
PLUGIN_PID=$!

if wait "$WATCHER_PID"; then
  note "PASS — $PLUGIN_ID registered"
  exit 0
fi

printf '\nthe plugin never registered within %ss. Its output:\n\n' "$TIMEOUT" >&2
tail -40 "$WORK/plugin.log" >&2
die "smoke test failed"
