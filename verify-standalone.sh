#!/usr/bin/env bash
#
# Build every repo in a meta-layout directory the way CI does: standalone.
#
#   ./verify-standalone.sh                 # plugins, clients, sdks
#   ./verify-standalone.sh plugins         # just one
#   CHECK=test ./verify-standalone.sh      # build + test instead of build
#
# WHY THIS EXISTS.
#
# The meta layout puts a `[workspace]` Cargo.toml in `plugins/`, `clients/` and
# `sdks/`. It is genuinely useful — one shared target dir, and a `[patch]`
# section redirecting hc-types and plugin-sdk-rs at local paths, which is the
# only sane way to develop an SDK change across thirteen plugins.
#
# It also lies to you, in two ways that both end in a green local build and a
# red CI:
#
#   1. LOCKFILES. Cargo run from inside a member resolves against the SHARED
#      lock and never touches the one that repo actually ships. Repos have been
#      found shipping locks that describe other plugins' dependency graphs,
#      because someone once ran cargo from the wrong directory.
#
#   2. FEATURE UNIFICATION. Cargo unifies features across workspace members. A
#      plugin that forgets to enable `plugin-sdk-rs/schema` still compiles,
#      because nine of its neighbours enabled it on the SDK's behalf. Standalone
#      it fails immediately. This is not hypothetical: hc-hue shipped exactly
#      that bug and the workspace build was green.
#
# Neither can be caught by building from the meta directory, by definition. So
# this moves the workspace manifest aside — making each repo its own root, which
# is what CI sees — builds each one with `--locked`, and always puts it back.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-build}"
DIRS=("${@:-plugins clients sdks}")
read -r -a DIRS <<< "${DIRS[*]}"

# Restoring the manifest matters more than anything else this script does:
# leaving it moved turns every later `cargo` in the tree into a slow,
# git-fetching standalone build with no obvious cause.
restore() {
  local d
  for d in "${DIRS[@]}"; do
    if [ -f "$ROOT/$d/Cargo.toml.verify-standalone" ]; then
      mv "$ROOT/$d/Cargo.toml.verify-standalone" "$ROOT/$d/Cargo.toml"
      echo "  [restored $d/Cargo.toml]"
    fi
  done
}
trap restore EXIT INT TERM

failed=0
for d in "${DIRS[@]}"; do
  [ -f "$ROOT/$d/Cargo.toml" ] || { echo "== $d: no meta workspace, skipping"; continue; }
  echo "== $d (cargo $CHECK --locked, standalone)"
  mv "$ROOT/$d/Cargo.toml" "$ROOT/$d/Cargo.toml.verify-standalone"

  for repo in "$ROOT/$d"/*/; do
    repo="${repo%/}"
    [ -f "$repo/Cargo.toml" ] || continue
    name="$(basename "$repo")"
    # --locked so a lockfile that disagrees with the manifest is an error here
    # rather than a silent re-resolve that only CI notices.
    if out=$(cd "$repo" && cargo "$CHECK" --locked 2>&1); then
      printf "  %-24s ok\n" "$name"
    else
      printf "  %-24s FAIL\n" "$name"
      echo "$out" | grep -E "^error" | head -3 | sed 's/^/      /'
      failed=1
    fi
  done

  mv "$ROOT/$d/Cargo.toml.verify-standalone" "$ROOT/$d/Cargo.toml"
done

if [ "$failed" -ne 0 ]; then
  echo
  echo "FAILED — at least one repo does not build the way CI will build it."
  exit 1
fi
echo
echo "All repos build standalone."
