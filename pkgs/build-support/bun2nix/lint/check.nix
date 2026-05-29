# Drift guard: assert that the committed bun.nix matches what bun2nix
# would generate from the committed bun.lock. Fails the check if they
# disagree.
#
# Bootstraps via `nix run .#regen-bun2nix-lint-stack` (see regen.nix). The check
# is sandboxed and pure — no network, only bun.lock and bun.nix as
# inputs, so the cache key isolates it from edits to package.json or
# eslint.config.js. It does not detect package.json → bun.lock drift;
# regen.nix is the only thing that can resolve semver.
{
  pkgs,
  bun2nix,
  bunLock,
  bunNix,
}:

pkgs.runCommand "bun2nix-lint-stack-up-to-date"
  {
    nativeBuildInputs = [ bun2nix ];
    inherit bunLock bunNix;
  }
  ''
    if ! [ -f "$bunLock" ] || ! [ -f "$bunNix" ]; then
      echo "bun2nix-lint-stack-up-to-date: bun.lock or bun.nix is missing from pkgs/build-support/bun2nix/lint/." >&2
      echo "" >&2
      echo "Bootstrap: nix run .#regen-bun2nix-lint-stack, then commit bun.lock and bun.nix." >&2
      exit 1
    fi

    bun2nix --lock-file="$bunLock" --output-file=./bun.nix.regenerated

    if ! diff -u "$bunNix" bun.nix.regenerated; then
      echo "" >&2
      echo "bun2nix-lint-stack-up-to-date: pkgs/build-support/bun2nix/lint/bun.nix is out of date relative to bun.lock." >&2
      echo "Fix: nix run .#regen-bun2nix-lint-stack, then commit the updated bun.nix." >&2
      exit 1
    fi

    touch $out
  ''
