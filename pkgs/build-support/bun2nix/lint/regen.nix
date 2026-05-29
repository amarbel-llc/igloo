# Regenerate pkgs/build-support/bun2nix/lint/{bun.lock,bun.nix} from package.json.
#
# Usage (impure, must run from the repo root — needs network):
#   nix run .#regen-bun2nix-lint-stack
#
# This is the impure half of the bootstrap problem: `bun install` must
# resolve semver ranges against the npm registry, which Nix derivations
# cannot do without a fixed-output hash. So we run it outside the
# sandbox via a flake app and commit the resulting lockfile + the
# bun2nix-generated bun.nix.
#
# The drift guard in check.nix verifies bun.nix is up to date relative
# to bun.lock at flake-check time. Drift between package.json and
# bun.lock can only be caught by re-running this script.
{
  pkgs,
  bun,
  bun2nix,
}:

pkgs.writeShellApplication {
  name = "regen-bun2nix-lint-stack";
  runtimeInputs = [
    bun
    bun2nix
    pkgs.coreutils
  ];
  text = ''
    set -euo pipefail

    if [ ! -f pkgs/build-support/bun2nix/lint/package.json ]; then
      echo "regen-bun2nix-lint-stack: run from the repo root (pkgs/build-support/bun2nix/lint/package.json must be visible)" >&2
      exit 2
    fi

    cd pkgs/build-support/bun2nix/lint

    bun install --linker=isolated
    bun2nix --lock-file=./bun.lock --output-file=./bun.nix
    rm -rf node_modules

    echo "regen-bun2nix-lint-stack: done. Review and commit bun.lock + bun.nix."
  '';
}
