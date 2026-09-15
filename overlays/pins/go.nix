# Named, cache-friendly Go toolchain attrs (see go-toolchain(7)).
#
# - `go_<major>_<minor>_<patch>` -> each registry entry, pinned and coexisting.
#
# nixpkgs' own `go` is deliberately NOT overridden (FDR 0012): the newest
# registry entry is reachable as `goToolchain.go` (overlays/amarbel-packages.nix),
# which igloo's Go builders take, so a registry bump never rebuilds the nixpkgs
# packages that take `go` (libcap and everything above it, buildGoModule tools).
#
# This pin references ONLY `prev` (never `final`) and uses the compiler-only
# `mkGo` helper, so the per-version attrs never force the gomod2nix builders.
# The toolchain machinery + registry live under
# pkgs/development/compilers/go-toolchain; this pin only surfaces attrs.
_final: prev:
let
  inherit (prev) lib;
  inherit
    (import ../../pkgs/development/compilers/go-toolchain/mk-go.nix {
      inherit (prev) lib fetchurl;
    })
    mkGo
    registry
    ;

  # "1.26.6" -> the nixpkgs base for its minor, from `prev` (no fixpoint cycle).
  baseFor =
    version: prev."go_${lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor version)}";

  # "1.26.6" -> "go_1_26_6"
  attrName = version: "go_${lib.replaceStrings [ "." ] [ "_" ] version}";
in
builtins.listToAttrs (
  map (e: {
    name = attrName e.version;
    value = mkGo {
      inherit (e) version;
      base = baseFor e.version;
    };
  }) registry
)
