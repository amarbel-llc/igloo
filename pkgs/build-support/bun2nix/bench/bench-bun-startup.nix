# Compare cold-start time: ESM bundle vs bytecode CJS.
#
# Validates the explicit decision in buildBunBinary to use --format=esm
# (so top-level await works) rather than --bytecode. Without this
# benchmark, the rationale for the format choice rots.
#
# Bytecode requires CJS (no top-level await), ESM supports TLA. The
# question this answers: how much cold-start does the ESM path cost
# relative to the bytecode path for a trivial entry, on this machine?
#
# Usage (impure — network only for first-build of hyperfine/bun, then
# pure runtime that shells out to bun/hyperfine):
#   nix run amarbel-llc/igloo#bench-bun-startup
#
# Ported from amarbel-llc/bun's justfile recipe `bench-startup` as
# part of amarbel-llc/nixpkgs#57. Rewritten as a writeShellApplication
# so it's runnable via `nix run` rather than a justfile recipe.
{
  pkgs,
  bun ? pkgs.bun,
  hyperfine ? pkgs.hyperfine,
}:

pkgs.writeShellApplication {
  name = "bench-bun-startup";
  runtimeInputs = [
    bun
    hyperfine
    pkgs.coreutils
  ];
  text = ''
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    echo 'console.log("hello");' > "$dir/entry.ts"
    bun build "$dir/entry.ts" --target=bun --format=esm --outdir="$dir/esm"
    bun build "$dir/entry.ts" --target=bun --bytecode --outdir="$dir/bytecode"
    hyperfine \
      --warmup 3 \
      --min-runs 50 \
      "bun $dir/esm/entry.js" \
      "bun $dir/bytecode/entry.js"
  '';
}
