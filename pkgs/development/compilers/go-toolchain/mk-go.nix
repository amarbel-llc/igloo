# mkGo — build ONLY the Go compiler for a registry version, from an explicitly
# supplied nixpkgs base. See go-toolchain(7).
#
# Deps are just lib + fetchurl (plus the `base` you pass), deliberately: the
# overlay pin builds `pkgs.go` / `pkgs.go_<x>_<y>_<z>` with this and references
# ONLY `prev`, so defining `go` never forces the gomod2nix builders (which
# reference `pkgs.go`) — which would be an overlay fixpoint cycle. The fuller
# `mkGoToolchain` bundle (compiler + builders) lives in default.nix and is
# consumer-facing, never used while the overlay is still defining `pkgs.go`.
{
  lib,
  fetchurl,
}:
let
  registry = import ./registry.nix;

  byVersion = builtins.listToAttrs (
    map (e: {
      name = e.version;
      value = e;
    }) registry
  );

  newest = lib.foldl' (
    acc: e: if builtins.compareVersions e.version acc > 0 then e.version else acc
  ) (builtins.head registry).version registry;

  mkGo =
    {
      # Registry version to build. Defaults to the newest registered version.
      version ? newest,
      # nixpkgs base derivation whose version+src are overridden. REQUIRED (the
      # caller supplies it from `prev` to keep the go-defining path acyclic).
      base,
      # src SRI hash; defaults to the registry entry's. Unused for a fork entry.
      hash ?
        (byVersion.${version} or (throw "go-toolchain: version ${version} is not in registry.nix")).hash,
      # FORK HATCH: a ready-made Go derivation used verbatim, bypassing
      # base+overrideAttrs. Defaults to the registry entry's goDrv, else null.
      goDrv ? (byVersion.${version} or { }).goDrv or null,
    }:
    if goDrv != null then
      goDrv
    else
      base.overrideAttrs (_: {
        inherit version;
        src = fetchurl {
          url = "https://go.dev/dl/go${version}.src.tar.gz";
          inherit hash;
        };
      });
in
{
  inherit mkGo registry newest;
}
