# Warm-cache POC for buildGoLint (spinclass#294, FDR 0006): lint a REAL
# goFlakeInputs-bridged module (spinclass: tommy, crap, ringmaster, dewey)
# cold vs. seeded from the deps-only mkGoLintCacheEnv snapshot.
#
# `tree` is a plain directory holding a spinclass source tree (the recipe
# `git archive`s HEAD into .tmp and appends a salt comment to a first-party
# file), passed as a path so pwd behaves like a consumer flake's `src = ./.`.
# `spinclass` is the checkout whose flake.lock supplies the bridged producers;
# getFlake of an unlocked git+file URL makes this impure eval (nix-build only).
#
# `real-warm` instead uses spinclass's own packages.default as `base` — the
# exact consumer shape (store-path src, postInstall, check-only inputs).
#
#   just explore-lint-warm-cache
{
  pkgs ? import ../.. { },
  spinclass,
  tree,
}:
let
  spinFlake = builtins.getFlake "git+file://${spinclass}";
  system = pkgs.stdenv.hostPlatform.system;
  treePath = /. + tree;

  base = pkgs.buildGoApplication {
    pname = "spinclass";
    pwd = treePath;
    src = builtins.path {
      path = treePath;
      name = "source";
    };
    goFlakeInputs = import (treePath + "/gomod.nix") {
      inherit (spinFlake.inputs)
        tommy
        crap
        ringmaster
        purse-first
        ;
      inherit system;
    };
    subPackages = [ "cmd/spinclass" ];
    GOTOOLCHAIN = "local";
    doCheck = false;
  };

  # Wall-clock the lint phase (cache seeding + golangci-lint) inside the
  # sandbox, so the number excludes nix eval and substitution.
  timed =
    lane: drv:
    drv.overrideAttrs (old: {
      preBuild = (old.preBuild or "") + ''
        warmCachePocStart=$EPOCHREALTIME
      '';
      postBuild = ''
        echo "warm-cache-poc[${lane}]: lint phase took $(awk "BEGIN { printf \"%.1f\", $EPOCHREALTIME - $warmCachePocStart }")s"
        echo "warm-cache-poc[${lane}]: GOLANGCI_LINT_CACHE holds $(find "$GOLANGCI_LINT_CACHE" -type f | wc -l) files after the run"
      ''
      + (old.postBuild or "");
    });

  lintOf =
    b: warmCache:
    pkgs.buildGoLint {
      base = b;
      inherit warmCache;
      golangci-lint = pkgs.golangci-lint;
      extraArgs = [ "-v" ];
    };

  warm = timed "warm" (lintOf base true);
  realWarm = timed "real-warm" (lintOf spinFlake.packages.${system}.default true);
in
{
  inherit warm;
  cold = timed "cold" (lintOf base false);
  inherit (warm) lintCacheEnv;
  real-warm = realWarm;
  realLintCacheEnv = realWarm.lintCacheEnv;
}
