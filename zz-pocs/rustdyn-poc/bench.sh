#!/usr/bin/env bash
# rustdyn POC benchmark harness (the zz-pocs/godyn-v2/bench.sh pattern).
#
#   bench.sh <work-dir> [runs] [approach...]
#
# Builds each approach (rustdyn: per-crate CA buildRustCrate; brp: the
# buildRustPackage baseline) under each scenario, `runs` times with a unique
# edit token per run, and emits one JSON object:
#   { runs, results: [ { approach, scenario, ms_min, ms_median, rebuilds } ] }
# Scenarios, all on posh-term (the crate every other member depends on):
#   warm          no edit
#   edit-leaf     a semantic edit to src/lib.rs
#   comment-leaf  a comment-only edit to src/lib.rs (does the rlib change?)
#   edit-test     a comment edit to tests/extensions.rs, a file the lib build
#                 never compiles: the derivation reruns, the rlib must not
#                 change, and the dependents must early-cut (the CA probe)
# `rebuilds` counts the crate derivations whose buildPhase ran (rust_* for
# rustdyn, posh-brp for the baseline); the resolver and vendor derivations are
# not counted.
#
# Every nix build is preceded by the host guard the operator set for this
# shared host (less than 4 GB available or load1 at 20 or more refuses a
# build); the harness waits for the host rather than aborting, up to 20 min.
set -uo pipefail
poc=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: bench.sh <work-dir> [runs] [approach...]}
runs=${2:-3}
shift 2 2>/dev/null || shift $#
approaches=("$@")
[ ${#approaches[@]} -gt 0 ] || approaches=(rustdyn brp)

leaf=$work/posh/crates/posh-term/src/lib.rs
testfile=$work/posh/crates/posh-term/tests/extensions.rs
[ -f "$leaf" ] || { echo "bench.sh: $leaf missing; run \`just setup\` first" >&2; exit 2; }

guard() {
  local avail_kb load1 waited=0
  while :; do
    avail_kb=$(awk '/MemAvailable/ { print $2 }' /proc/meminfo)
    load1=$(cut -d' ' -f1 /proc/loadavg)
    if (( avail_kb >= 4 * 1024 * 1024 )) && (( ${load1%.*} < 20 )); then
      return 0
    fi
    if (( waited >= 1200 )); then
      echo "bench.sh: host guard refused a build for 20 min: MemAvailable=${avail_kb}kB load1=${load1}" >&2
      exit 75
    fi
    echo "bench.sh: host busy (MemAvailable=${avail_kb}kB load1=${load1}); waiting 30 s" >&2
    sleep 30
    waited=$((waited + 30))
  done
}

# Restore both edited files byte-for-byte: drop the probe lines and the blank
# line the semantic edit adds in front of its function.
pristine() {
  for f in "$leaf" "$testfile"; do
    sed -i '/rustdyn_poc_probe/d; /rustdyn poc probe/d' "$f"
    sed -i '${/^$/d}' "$f"
  done
}
applyedit() { # $1=semantic|comment|test
  case "$1" in
    semantic) printf '\npub fn rustdyn_poc_probe() -> u32 { 1%s }\n' "$RANDOM" >>"$leaf" ;;
    comment) echo "// rustdyn poc probe $RANDOM$RANDOM" >>"$leaf" ;;
    test) echo "// rustdyn poc probe $RANDOM$RANDOM" >>"$testfile" ;;
  esac
}
expr_for() { # $1=attr
  printf '(import %s/poc.nix { poshSrc = %s/posh; }).%s' "$poc" "$work" "$1"
}
onebuild() { # $1=attr -> "<ms> <rebuilds>"
  local attr=$1 log t0 t1 rb
  guard
  log=$(mktemp "$work/build.XXXXXX.log")
  t0=$(date +%s%3N)
  if ! nix build --impure --no-link -L --expr "$(expr_for "$attr")" >/dev/null 2>"$log"; then
    echo "bench.sh: build of $attr failed; log: $log" >&2
    exit 1
  fi
  t1=$(date +%s%3N)
  rb=$(grep -oE '^[^> ]+> Running phase: buildPhase' "$log" | sort -u | grep -cE '^(rust_|posh-brp)' || true)
  rm -f "$log"
  echo "$((t1 - t0)) ${rb:-0}"
}
scenario() { # $1=approach $2=editkind("" for none) $3=scenario-name -> one json object
  local a=$1 ek=$2 name=$3 times=() rb=0 ms r
  for _ in $(seq "$runs"); do
    pristine
    [ -n "$ek" ] && applyedit "$ek"
    read -r ms r < <(onebuild "$a")
    times+=("$ms")
    rb=$r
  done
  pristine
  local sorted n
  mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
  n=${#sorted[@]}
  jq -nc --arg a "$a" --arg s "$name" \
    --argjson mn "${sorted[0]}" --argjson md "${sorted[$((n / 2))]}" --argjson rb "$rb" \
    '{approach:$a, scenario:$s, ms_min:$mn, ms_median:$md, rebuilds:$rb}'
}

pristine
{
  for a in "${approaches[@]}"; do
    scenario "$a" "" warm
    scenario "$a" semantic edit-leaf
    scenario "$a" comment comment-leaf
    scenario "$a" test edit-test
  done
} | jq -s --argjson r "$runs" '{runs:$r, results:.}'
