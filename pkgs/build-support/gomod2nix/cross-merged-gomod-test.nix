# Regression test for amarbel-llc/igloo#44: mkMergedGoMod must run `go mod
# edit` with a BUILD-platform go. Under a cross pkgs set, `buildInputs` are
# host-platform packages that never reach the builder's PATH, so the
# merged-go.mod derivation died with `go: command not found`; the go belongs
# in `nativeBuildInputs`, where stdenv splices it to buildPackages' go.
#
# Eval-only on the cross side: the test inspects the merged-go.mod derivation's
# input lists under pkgsCross.aarch64-multiplatform and builds nothing for
# aarch64. The build-platform run of the same helper is covered by
# internals-merge-test.nix.
# Build with: nix-build pkgs/build-support/gomod2nix/cross-merged-gomod-test.nix
{
  pkgs ? import ../../.. { },
}:
let
  inherit (pkgs) lib;
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  inherit (import ./internals.nix { }) mkMergedGoMod;

  consumerGoMod = pkgs.writeText "consumer-go.mod" ''
    module example.com/consumer

    go 1.26
  '';
  dummySrc = pkgs.runCommand "dummy-src" { } "mkdir -p $out";

  # What buildGoApplication does under a cross pkgs set: the selected `go` and
  # `runCommand` come from the cross set, so `go` is the HOST-platform
  # compiler and only splicing can make a build-platform one run.
  merged = mkMergedGoMod {
    inherit consumerGoMod;
    inherit (cross) go runCommand;
    goFlakeInputs = {
      "github.com/amarbel-llc/tap/go" = dummySrc;
    };
  };

  outPaths = map (d: d.outPath) (lib.filter lib.isDerivation merged.nativeBuildInputs);
  buildGo = cross.buildPackages.go.outPath;
  hostGo = cross.go.outPath;

  checks = [
    {
      name = "#44 nativeBuildInputs carries the build-platform go";
      ok = lib.elem buildGo outPaths;
    }
    {
      name = "#44 nativeBuildInputs does not carry the host-platform go";
      ok = !(lib.elem hostGo outPaths);
    }
    {
      name = "#44 buildInputs carries no go at all";
      ok = !(lib.any (d: lib.isDerivation d && (d.pname or "") == "go") merged.buildInputs);
    }
  ];
  failed = lib.filter (c: !c.ok) checks;
in
if failed != [ ] then
  throw "cross-merged-gomod-test: ${lib.concatMapStringsSep "; " (c: "FAIL ${c.name}") failed}"
else
  pkgs.runCommand "cross-merged-gomod-test" { } ''
    ${lib.concatMapStringsSep "\n" (c: "echo 'ok ${c.name}'") checks}
    touch $out
  ''
