# go-toolchain — version-parameterized Go toolchains for the igloo overlay.
# See go-toolchain(7).
#
# `mkGo` (compiler only) lives in ./mk-go.nix and is re-exported here; the
# overlay pin uses it directly (via `prev`) to build the `go` / `go_<x>_<y>_<z>`
# attrs without cycling through the gomod2nix builders.
#
# `mkGoToolchain` bundles that compiler with matching builders (buildGoModule /
# buildGoApplication / mkGoEnv) bound to it, so a consumer's build-time and
# devshell Go stay in lockstep. It is consumer-facing and is NOT used while the
# overlay is still defining `pkgs.go`.
{
  lib,
  fetchurl,
  buildGoModule,
  buildGoApplication,
  mkGoEnv,
  # nixpkgs bases, one per Go minor the registry references. Add a new minor
  # here (and in `bases` below) when the registry first carries that minor.
  go_1_25,
  go_1_26,
}:
let
  inherit (import ./mk-go.nix { inherit lib fetchurl; }) mkGo registry newest;

  # Go minor (e.g. "1.26") -> the nixpkgs base derivation to override.
  bases = {
    "1.25" = go_1_25;
    "1.26" = go_1_26;
  };

  mkGoToolchain =
    {
      version ? newest,
      base ?
        bases.${lib.versions.majorMinor version}
        or (throw "go-toolchain: no nixpkgs base for Go ${lib.versions.majorMinor version}; add it to `bases` in default.nix, or register a { version; goDrv; } fork entry"),
    }:
    let
      go = mkGo { inherit version base; };
    in
    {
      inherit go;
      buildGoModule = buildGoModule.override { inherit go; };
      buildGoApplication = args: buildGoApplication (args // { inherit go; });
      mkGoEnv = args: mkGoEnv (args // { inherit go; });
    };
in
{
  inherit
    mkGo
    mkGoToolchain
    registry
    newest
    ;
}
