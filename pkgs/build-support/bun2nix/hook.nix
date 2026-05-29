# Setup hook for bun2nix builds.
# Requires bunDeps (output of fetchBunDeps) to be set.
{ pkgs, lib, bun, bun2nixNoOp }:

pkgs.makeSetupHook {
  name = "bun2nix-hook";
  propagatedBuildInputs = [
    bun2nixNoOp
    bun
    pkgs.yq-go
  ];
  substitutions = {
    bunDefaultInstallFlags = lib.concatStringsSep " " (
      if pkgs.stdenv.hostPlatform.isDarwin then
        [
          "--linker=isolated"
          "--backend=symlink"
        ]
      else
        [
          "--linker=isolated"
        ]
    );
  };
} ./hook.sh
