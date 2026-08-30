# Named, cache-friendly Go toolchain attrs (see go-toolchain(7)).
#
# - `go`                         -> the NEWEST registry version (overrides the
#                                   default toolchain the whole overlay uses).
# - `go_<major>_<minor>_<patch>` -> each registry entry, pinned and coexisting.
#
# This pin references ONLY `prev` (never `final`) and uses the compiler-only
# `mkGo` helper: defining `go` therefore never forces the gomod2nix builders
# (which reference `go`), avoiding an overlay fixpoint cycle. The toolchain
# machinery + registry live under pkgs/development/compilers/go-toolchain; this
# pin only surfaces attrs.
_final: prev:
let
  inherit (prev) lib;
  inherit
    (import ../../pkgs/development/compilers/go-toolchain/mk-go.nix {
      inherit (prev) lib fetchurl;
    })
    mkGo
    registry
    newest
    ;

  # "1.26.6" -> the nixpkgs base for its minor, from `prev` (no fixpoint cycle).
  baseFor =
    version: prev."go_${lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor version)}";

  # "1.26.6" -> "go_1_26_6"
  attrName = version: "go_${lib.replaceStrings [ "." ] [ "_" ] version}";

  perVersion = builtins.listToAttrs (
    map (e: {
      name = attrName e.version;
      value = mkGo {
        inherit (e) version;
        base = baseFor e.version;
      };
    }) registry
  );
in
perVersion
// {
  # Default Go = newest registered version. Overriding `go` also updates every
  # tool that defaults to it (nixpkgs `buildGoModule`, gomod2nix builders).
  go = mkGo {
    version = newest;
    base = baseFor newest;
  };
}
