#!/usr/bin/env bash
# godyn-v2 crossover sweep.
#
#   sweep.sh "10 30 60 120 240" [runs]
#
# Finds the module size at which the native eval-time graph's incremental edit
# beats buildGoApplication's whole-module rebuild. For each N it generates a
# synthetic "wide-star" module (a `main` importing N-1 independent leaf packages),
# then times editing ONE leaf: under native that rebuilds cone=2 (the leaf + main),
# under bga it rebuilds the whole module. Emits JSON:
#   { runs, points: [ {n, native_edit_ms, bga_edit_ms, native_wins} ], crossover_n }
# Built via `nix build --impure --expr` over a /tmp module, so no git involvement.
set -uo pipefail

root=/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany
v2=$root/zz-pocs/godyn-v2
sizes=${1:-"10 30 60 120"}
runs=${2:-2}
work=$(mktemp -d /tmp/godyn-sweep.XXXXXX)

goStore=$(nix build --no-link --print-out-paths "$v2/../godyn-poc#go-toolchain^out" 2>/dev/null)
gen=$work/godyn-gen
(cd "$v2/gen" && PATH="$goStore/bin:$PATH" GOCACHE=$(mktemp -d) go build -o "$gen" .)

gen_synth() { # N dir
  local N=$1 d=$2 i p imp="" sum="0"
  rm -rf "$d"
  mkdir -p "$d/internal"
  printf 'module example.com/synth\n\ngo 1.26\n' >"$d/go.mod"
  printf 'schema = 3\n\n[mod]\n' >"$d/gomod2nix.toml"
  for ((i = 0; i < N - 1; i++)); do
    p=$(printf 'p%05d' "$i")
    mkdir -p "$d/internal/$p"
    printf 'package %s\n\nfunc F() int { return %d }\n' "$p" "$i" >"$d/internal/$p/$p.go"
    imp+=$'\t'"\"example.com/synth/internal/$p\""$'\n'
    sum+=" + $p.F()"
  done
  printf 'package main\n\nimport (\n\t"fmt"\n%s)\n\nfunc main() { fmt.Println(%s) }\n' "$imp" "$sum" >"$d/main.go"
}

native_expr() { # dir
  echo "let f = builtins.getFlake \"git+file://$root\"; p = f.legacyPackages.x86_64-linux; go = p.go; stdlib = p.callPackage $v2/../godyn-poc/stdlib.nix { inherit go; }; in p.callPackage $v2/native.nix { inherit go stdlib; src = $1; graphFile = $1/graph.json; pname = \"synth\"; }"
}
bga_expr() { # dir
  echo "let f = builtins.getFlake \"git+file://$root\"; p = f.legacyPackages.x86_64-linux; in p.buildGoApplication { pname = \"synth\"; version = \"0\"; src = $1; modules = $1/gomod2nix.toml; }"
}
build() { # expr -> ms (wall)
  local t0 t1 bt
  bt=$(mktemp -d /tmp/godyn-v2.XXXXXX)
  t0=$(date +%s%3N)
  TMPDIR=$bt nix build --impure --no-link -L --expr "$1" >/dev/null 2>"$work/b.err"
  t1=$(date +%s%3N)
  echo "$((t1 - t0))"
}
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$0} END{print a[int((NR+1)/2)]}'; }

points=()
for N in $sizes; do
  d=$work/synth
  gen_synth "$N" "$d"
  (cd "$d" && PATH="$goStore/bin:$PATH" GOCACHE=$(mktemp -d) GOFLAGS=-mod=mod "$gen" "$d" "$d/graph.json") 2>/dev/null
  ne=() be=()
  # warm both once (cold-build the graph), then time `runs` distinct leaf edits.
  build "$(native_expr "$d")" >/dev/null
  build "$(bga_expr "$d")" >/dev/null
  for _ in $(seq "$runs"); do
    printf '\nfunc gdProbe() int { return 1%s }\n' "$RANDOM" >>"$d/internal/p00000/p00000.go"
    ne+=("$(build "$(native_expr "$d")")")
    be+=("$(build "$(bga_expr "$d")")")
    sed -i '/gdProbe/d' "$d/internal/p00000/p00000.go"
    sed -i '${/^$/d}' "$d/internal/p00000/p00000.go"
  done
  nm=$(median "${ne[@]}")
  bm=$(median "${be[@]}")
  win=$([ "$nm" -lt "$bm" ] && echo true || echo false)
  echo "  N=$N  native_edit=${nm}ms  bga_edit=${bm}ms  native_wins=$win" >&2
  points+=("{\"n\":$N,\"native_edit_ms\":$nm,\"bga_edit_ms\":$bm,\"native_wins\":$win}")
done

# crossover = smallest N where native_wins flips to true
cross=null
for pt in "${points[@]}"; do
  n=$(sed -E 's/.*"n":([0-9]+).*/\1/' <<<"$pt")
  w=$(grep -q '"native_wins":true' <<<"$pt" && echo 1 || echo 0)
  [ "$w" = 1 ] && {
    cross=$n
    break
  }
done
printf '{"runs":%s,"crossover_n":%s,"points":[%s]}\n' "$runs" "$cross" "$(
  IFS=,
  echo "${points[*]}"
)"
rm -rf "$work"
