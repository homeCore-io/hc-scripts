#!/usr/bin/env bash
# smoke-node-artifact.sh — Prove a built Node artifact actually runs.
#
# The way a Node runtime runs it (docker/runtime-node/adapter.toml in core):
#
#   1. unpack the tarball
#   2. `node --check app/<entrypoint>` on the interpreter, as the install step does
#   3. launch it against a scratch broker with nothing but what it carries
#   4. wait for it to register a device, publish its capabilities or report
#      itself active
#
# Step 4 is the one that matters: only registering proves the SDK loaded, every
# dependency was in node_modules, and the plugin got far enough to say hello.
#
# Usage:
#   smoke-node-artifact.sh --artifact <file.tar.zst> [options]
#
# Options:
#   --artifact     the .tar.zst to test                           (required)
#   --interpreter  an unpacked homeCore Node interpreter (the folder holding
#                  node/): run exactly as a runtime does   (default: node on PATH)
#   --broker-host  MQTT broker                             (default: 127.0.0.1)
#   --broker-port  MQTT port                                     (default: 1883)
#   --timeout      seconds to wait for registration                (default: 45)
#   --help
set -euo pipefail

ARTIFACT=""
INTERPRETER=""
BROKER_HOST="127.0.0.1"
BROKER_PORT="1883"
TIMEOUT=45

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact)    ARTIFACT="${2:?}"; shift 2 ;;
    --interpreter) INTERPRETER="${2:?}"; shift 2 ;;
    --broker-host) BROKER_HOST="${2:?}"; shift 2 ;;
    --broker-port) BROKER_PORT="${2:?}"; shift 2 ;;
    --timeout)     TIMEOUT="${2:?}"; shift 2 ;;
    --help|-h)     sed -n '2,25p' "$0"; exit 0 ;;
    *)             die "unknown option: $1" ;;
  esac
done

[[ -f "$ARTIFACT" ]] || die "--artifact is required and must exist"
if [[ -n "$INTERPRETER" ]]; then
  # Absolute: the plugin is launched from inside the work folder, where a
  # relative path (the release workflow passes .interp) no longer resolves.
  INTERPRETER="$(cd "$INTERPRETER" 2>/dev/null && pwd)" || die "--interpreter: no such folder"
  NODE="$INTERPRETER/node/bin/node"
  [[ -x "$NODE" ]] || die "--interpreter $INTERPRETER has no node/bin/node"
else
  NODE="$(command -v node)" || die "node is required, or --interpreter"
fi
ARTIFACT="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"

WORK="$(mktemp -d)"
trap 'kill "${PLUGIN_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

note "unpacking $(basename "$ARTIFACT")"
tar -C "$WORK" --zstd -xf "$ARTIFACT"
[[ -f "$WORK/plugin.toml" && -d "$WORK/app" ]] || die "the artifact has no plugin.toml and app/ at its root"

field() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"$/\1/p" "$WORK/plugin.toml" | head -1; }
PLUGIN_ID="$(field id)"
ENTRYPOINT="$(field entrypoint)"
ABI="$(field abi)"
[[ -n "$PLUGIN_ID" && -n "$ENTRYPOINT" ]] || die "plugin.toml has no id or entrypoint"
WANT_MAJOR="${ABI%%-*}"; WANT_MAJOR="${WANT_MAJOR#node}"
HAVE_MAJOR="$("$NODE" -p 'process.versions.node.split(".")[0]')"
[[ "$HAVE_MAJOR" == "$WANT_MAJOR" ]] || die "the artifact is built for Node $WANT_MAJOR and this is $("$NODE" -v)"

note "checking it parses on $("$NODE" -v), as the runtime's install step does"
"$NODE" --check "$WORK/app/$ENTRYPOINT" || die "$ENTRYPOINT does not parse"

cat > "$WORK/config.toml" <<EOF
[homecore]
broker_host = "$BROKER_HOST"
broker_port = $BROKER_PORT
plugin_id = "$PLUGIN_ID"
password = "smoke"
EOF

# The watcher uses the artifact's own mqtt (the SDK's dependency), so the
# smoke test needs nothing the artifact doesn't carry.
note "watching for $PLUGIN_ID to register"
cat > "$WORK/watch.js" <<'JS'
const [host, port, id, timeout] = process.argv.slice(2);
const mqtt = require(process.env.MQTT_PATH);
const c = mqtt.connect({ host, port: Number(port), clientId: `smoke-${process.pid}` });
const done = (ok) => { c.end(true); process.exit(ok ? 0 : 1); };
setTimeout(() => done(false), Number(timeout) * 1000);
c.on("connect", () => {
  for (const t of ["register", "capabilities", "status"]) c.subscribe(`homecore/plugins/${id}/${t}`, { qos: 1 });
});
c.on("message", (topic, payload) => {
  if (topic.endsWith("/status") && payload.toString().trim() !== "active") return;
  console.log(`saw ${topic}`);
  done(true);
});
JS
MQTT_PATH="$WORK/app/node_modules/mqtt" "$NODE" "$WORK/watch.js" \
  "$BROKER_HOST" "$BROKER_PORT" "$PLUGIN_ID" "$TIMEOUT" > "$WORK/watch.log" 2>&1 &
WATCHER_PID=$!
sleep 2

note "launching the plugin"
(cd "$WORK" && NODE_ENV=production "$NODE" --enable-source-maps "$WORK/app/$ENTRYPOINT" "$WORK/config.toml") \
  > "$WORK/plugin.log" 2>&1 &
PLUGIN_PID=$!

if wait "$WATCHER_PID"; then
  note "PASS — $PLUGIN_ID registered ($(cat "$WORK/watch.log"))"
  exit 0
fi
printf '\nthe plugin never registered within %ss. Its output:\n\n' "$TIMEOUT" >&2
tail -40 "$WORK/plugin.log" >&2
tail -5 "$WORK/watch.log" >&2
die "smoke test failed"
