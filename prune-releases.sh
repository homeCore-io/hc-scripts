#!/usr/bin/env bash
# prune-releases.sh — Keep the newest few GitHub releases of each component.
#
# A monorepo tags every component: `v0.1.108` is core, `hc-hue-v0.2.8` is a
# plugin. Each release carries its built files, and they pile up: every
# version of every plugin, for every architecture. This keeps the newest N
# releases per component and deletes the rest, files and all.
#
# The git tags stay, so history and `git checkout v0.1.80` still work; only the
# GitHub release and its files go. Pair it with the registry's Prune workflow,
# which takes the same versions out of the index (an index entry pointing at a
# deleted release would fail to install).
#
# A release the registry index still points at is never deleted, whatever its
# age: the index decides what is installable, and its newest three are not
# always the newest three releases. Prune the index first, then this.
#
# Lists what would go unless --apply is given.
#
# Usage:
#   prune-releases.sh [--repo homeCore-io/homeCore] [--keep 3]
#                     [--index https://homecore.io/registry/index.json] [--apply]

set -euo pipefail

REPO="homeCore-io/homeCore"
KEEP=3
APPLY=0
INDEX="https://homecore.io/registry/index.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --keep)  KEEP="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --index) INDEX="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "--keep must be 1 or more" >&2; exit 2; }
command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }

# Tags the index points at: their releases stay.
if [[ "$INDEX" == http* ]]; then
  index_json=$(curl -fsSL "$INDEX") || { echo "could not read the index at $INDEX" >&2; exit 1; }
else
  index_json=$(cat "$INDEX")
fi
declare -A IN_INDEX=()
while read -r t; do
  [[ -n "$t" ]] && IN_INDEX["$t"]=1
done < <(printf '%s' "$index_json" | grep -oE "github.com/$REPO/releases/download/[^/\"]+" | sed 's#.*/download/##' | sort -u)
echo "the index points at ${#IN_INDEX[@]} releases in $REPO; those stay"

# Every release tag, then component and version split apart:
#   v0.1.108        -> core      0.1.108
#   hc-hue-v0.2.8   -> hc-hue    0.2.8
# Tags that are not versions (a rolling `latest`, say) are left alone.
mapfile -t TAGS < <(gh release list -R "$REPO" --limit 2000 --json tagName -q '.[].tagName')

declare -A BY_COMPONENT=()
for tag in "${TAGS[@]}"; do
  if [[ "$tag" =~ ^(.*-)?v([0-9]+(\.[0-9]+)*)$ ]]; then
    comp="${BASH_REMATCH[1]%-}"
    comp="${comp:-core}"
    BY_COMPONENT["$comp"]+="${BASH_REMATCH[2]} $tag"$'\n'
  fi
done

total=0
for comp in $(printf '%s\n' "${!BY_COMPONENT[@]}" | sort); do
  # Newest first by version number, so 0.1.10 comes before 0.1.9.
  mapfile -t candidates < <(printf '%s' "${BY_COMPONENT[$comp]}" | sort -t' ' -k1,1 -V -r | tail -n +"$((KEEP + 1))" | cut -d' ' -f2)
  old=()
  for tag in "${candidates[@]}"; do
    [[ -n "${IN_INDEX[$tag]:-}" ]] || old+=("$tag")
  done
  [[ ${#old[@]} -eq 0 ]] && continue
  total=$((total + ${#old[@]}))
  echo "$comp: ${#old[@]} older than the newest $KEEP: ${old[*]}"
  if [[ $APPLY -eq 1 ]]; then
    for tag in "${old[@]}"; do
      gh release delete "$tag" -R "$REPO" --yes >/dev/null
    done
  fi
done

if [[ $total -eq 0 ]]; then
  echo "nothing to prune in $REPO"
elif [[ $APPLY -eq 1 ]]; then
  echo "deleted $total releases from $REPO (their tags remain)"
else
  echo "would delete $total releases from $REPO (their tags remain). Run with --apply to delete them."
fi
