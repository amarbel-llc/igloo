#!/usr/bin/env bash
# godyn-v2 JSON benchmark harness.
#
#   bench.sh <toy|tommy> [runs]
#
# Builds each approach (native eval-graph / recursive resolver / buildGoApplication)
# under each scenario (warm / edit-bottom / edit-mid / comment-bottom), `runs`
# times with a unique edit token each time, and emits structured JSON:
#   { module, packages, runs, results: [ {approach, scenario, ms_min, ms_median, rebuilds} ] }
# ms_* is wall-clock; rebuilds is packages nix actually recompiled (meaningful for
# the native graph; the recursive/bga build is one wrapper/module derivation).
set -uo pipefail
cd "$(dirname "$0")"

module=${1:-toy}
runs=${2:-3}

case "$module" in
  toy)
    approaches=(native recursive bga)
    fbottom=module/internal/leaf/leaf.go
    fmid=module/internal/top/top.go
    npkg=4 ;;
  tommy)
    approaches=(tommy-native tommy-recursive tommy-bga)
    fbottom=$(ls tommy-lib/internal/ringbuf/*.go | grep -v _test | head -1)
    fmid=$(ls tommy-lib/pkg/cst/*.go | grep -v _test | head -1)
    npkg=7 ;;
  *)
    echo "usage: bench.sh <toy|tommy> [runs]" >&2; exit 1 ;;
esac

log=$(mktemp -d)
pristine() { for f in "$fbottom" "$fmid"; do sed -i '/gdProbe/d; /godyn probe/d' "$f"; sed -i '${/^$/d}' "$f"; done; }
applyedit() {
  case "$2" in
    semantic) printf '\nfunc gdProbe() int { return 1%s }\n' "$RANDOM" >> "$1" ;;
    comment)  echo "// godyn probe $RANDOM$RANDOM" >> "$1" ;;
  esac
}
onebuild() { # $1=target -> "<ms> <rebuilds>"
  local bt t0 t1 rb
  bt=$(mktemp -d /tmp/godyn-v2.XXXXXX)
  t0=$(date +%s%3N)
  TMPDIR=$bt nix build ".#$1" -L --no-link >/dev/null 2>"$log/b.err"
  t1=$(date +%s%3N)
  rb=$(grep -cE "building '.*-compile-" "$log/b.err" 2>/dev/null || true)
  echo "$((t1 - t0)) ${rb:-0}"
}
scenario() { # $1=approach $2=editfile("" for none) $3=editkind $4=scenario-name -> one json object
  local a=$1 ef=$2 ek=$3 name=$4 times=() rb=0 ms r
  for _ in $(seq "$runs"); do
    pristine
    [ -n "$ef" ] && applyedit "$ef" "$ek"
    read -r ms r < <(onebuild "$a")
    times+=("$ms"); rb=$r
  done
  pristine
  local sorted; mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
  local n=${#sorted[@]}
  jq -nc --arg a "$a" --arg s "$name" \
    --argjson mn "${sorted[0]}" --argjson md "${sorted[$((n / 2))]}" --argjson rb "$rb" \
    '{approach:$a, scenario:$s, ms_min:$mn, ms_median:$md, rebuilds:$rb}'
}

pristine
{
  for a in "${approaches[@]}"; do
    scenario "$a" "" ""        warm
    scenario "$a" "$fbottom" semantic edit-bottom
    scenario "$a" "$fmid"    semantic edit-mid
    scenario "$a" "$fbottom" comment  comment-bottom
  done
} | jq -s --arg m "$module" --argjson p "$npkg" --argjson r "$runs" \
  '{module:$m, packages:$p, runs:$r, results:.}'
