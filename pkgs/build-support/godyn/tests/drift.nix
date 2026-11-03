# go.nix staleness (igloo#98): driftCheck over the manifest fixture. Its own
# producer (tests/cross: go 1.26, no requires) leaves it fresh; a bumped producer
# (tests/manifest-drift: go 1.26.0 and go-cmp v0.7.0, pinned in the root
# gomod2nix.toml its dep/ subPath falls back to) leaves go.nix behind on the go
# line and go-cmp. The check fails naming both and the repair; its codegenPatch
# rewrites go.nix to the committed expected.go.nix, which is fresh.
{
  pkgs,
  # a buildGoAuto module over the manifest fixture (its passthru.manifestDrift)
  manifestAuto,
}:
let
  inherit (pkgs) lib;
  m = pkgs.callPackage ../manifest.nix { };
  manifest = ./manifest/go.nix;
  depAt = src: {
    "example.com/dep" = {
      inherit src;
      subPath = "dep";
    };
  };
  bumpedDep = depAt ./manifest-drift;
  # the bumped go.mod without any gomod2nix.toml: no pin, so no repair patch
  unpinnedDep = depAt (
    lib.fileset.toSource {
      root = ./manifest-drift;
      fileset = ./manifest-drift/dep;
    }
  );

  freshCheck = m.driftCheck {
    pname = "godyn-manifest-drift-fresh";
    inherit manifest;
    goFlakeInputs = depAt ./cross;
  };
  bumpedCheck = m.driftCheck {
    pname = "godyn-manifest-drift-bumped";
    inherit manifest;
    goFlakeInputs = bumpedDep;
    codegenPrefix = "pkgs/build-support/godyn/tests/manifest";
  };
  bumped = bumpedCheck.passthru.drift;
  unpinnedCheck = m.driftCheck {
    pname = "godyn-manifest-drift-unpinned";
    inherit manifest;
    goFlakeInputs = unpinnedDep;
  };
  unpinned = unpinnedCheck.passthru.drift;
  # go.nix replacing go-cmp (an attrset manifest: no file for a patch either)
  replacedCheck = m.driftCheck {
    pname = "godyn-manifest-drift-replaced";
    manifest = m.load manifest // {
      replace."github.com/google/go-cmp" = {
        module = "github.com/google/go-cmp";
        version = "v0.6.0";
      };
    };
    goFlakeInputs = bumpedDep;
  };
  replaced = replacedCheck.passthru.drift;

  repaired =
    pkgs.runCommandLocal "godyn-manifest-drift-repaired" { nativeBuildInputs = [ pkgs.git ]; }
      ''
        mkdir "$out"
        cp --no-preserve=mode ${manifest} "$out/go.nix"
        cd "$out"
        git apply -p2 ${bumpedCheck.passthru.codegenPatch}/patch
      '';

  lt =
    cmp: a: b:
    cmp a b < 0;
  modLt = lt m.compareModuleVersions;
  goLt = lt m.compareGoVersions;
in
# the orders cmd/go uses (x/mod/semver, go/version)
assert modLt "v0.43.0" "v0.49.0";
assert modLt "v0.9.0" "v0.10.0";
assert modLt "v1.2.3-pre" "v1.2.3";
assert modLt "v0.0.0-20231010123456-abcdef123456" "v0.0.1";
assert modLt "v1.2.3" "v1.2.4-0.20231010123456-abcdef123456";
assert modLt "v1.0.0-alpha.1" "v1.0.0-alpha.beta";
assert modLt "v1.0.0-rc.2" "v1.0.0-rc.10";
assert modLt "v1.0.0-rc" "v1.0.0-rc.1";
assert m.compareModuleVersions "v2.0.0+incompatible" "v2.0.0" == 0;
assert goLt "1.26" "1.26rc1";
assert goLt "1.26rc1" "1.26.0";
assert goLt "1.26.0" "1.26.1";
assert goLt "1.21beta1" "1.21rc1";
assert goLt "1.9" "1.10";
assert m.compareGoVersions "1.26.0" "1.26.0" == 0;
# fresh
assert !freshCheck.passthru.drift.stale;
assert freshCheck.passthru.drift.producers == [ "example.com/dep" ];
# bumped: both raises, repairable, and the repaired manifest is fresh
assert bumped.stale && bumped.repairable;
assert
  bumped.go == {
    have = "1.26";
    want = "1.26.0";
    from = [ "example.com/dep's go.mod" ];
  };
assert
  bumped.requires."github.com/google/go-cmp" == {
    have = "v0.6.0";
    want = "v0.7.0";
    requiredBy = [ "example.com/dep" ];
    problem = null;
    entry = {
      version = "v0.7.0";
      hash = "sha256-JbxZFBFGCh/Rj5XZ1vG94V2x7c18L8XKB0N9ZD5F2rM=";
      go = "1.21";
    };
  };
assert
  !(m.drift {
    manifest = bumped.expected;
    goFlakeInputs = bumpedDep;
  }).stale;
assert m.renderGoNix bumped.expected == builtins.readFile ./manifest-drift/expected.go.nix;
# unrepairable raises still fail the check, with an empty patch
assert unpinned.stale && !unpinned.repairable;
assert
  unpinned.requires."github.com/google/go-cmp".problem
  == "no bridged producer's gomod2nix.toml pins v0.7.0";
# the go line is still raised to the producer's (go-cmp's go stays 1.13)
assert unpinned.go.want == "1.26.0";
assert replaced.stale && !replaced.repairable;
assert replaced.requires."github.com/google/go-cmp".problem == "go.nix replaces it";
{
  # fresh: the check passes (building it is the assertion), also as buildGoAuto
  # wires it; empty patches where no repair applies; the bumped patch repairs
  # go.nix to expected.go.nix
  godyn-manifest-drift-test = pkgs.runCommandLocal "godyn-manifest-drift-test-check" { } ''
    [ ! -s ${freshCheck.passthru.codegenPatch}/patch ] || { echo "fresh: codegenPatch not empty" >&2; exit 1; }
    [ -s ${bumpedCheck.passthru.codegenPatch}/patch ] || { echo "bumped: empty codegenPatch" >&2; exit 1; }
    [ ! -s ${unpinnedCheck.passthru.codegenPatch}/patch ] || { echo "unpinned: codegenPatch not empty" >&2; exit 1; }
    [ ! -s ${replacedCheck.passthru.codegenPatch}/patch ] || { echo "replaced: codegenPatch not empty" >&2; exit 1; }
    diff -u ${./manifest-drift/expected.go.nix} ${repaired}/go.nix
    echo ${freshCheck} ${manifestAuto.passthru.manifestDrift { }} > $out
  '';
  # bumped: the check fails naming each raise and the repairs
  godyn-manifest-drift-fail-test = pkgs.testers.testBuildFailure' {
    drv = bumpedCheck;
    expectedBuilderLogEntries = [
      "go: 1.26 -> 1.26.0 (example.com/dep's go.mod)"
      "require.github.com/google/go-cmp: v0.6.0 -> v0.7.0 (required by example.com/dep's go.mod)"
      "godyn go.nix drift (godyn-manifest-drift-bumped): repair from the directory holding go.nix: godyn-go -- go mod tidy"
      "git apply -p2 --directory=pkgs/build-support/godyn/tests/manifest "
    ];
  };
  # unpinned: still fails, naming why there is no patch, and offers none
  godyn-manifest-drift-unpinned-test = pkgs.testers.testBuildFailure' {
    drv = unpinnedCheck;
    expectedBuilderLogEntries = [
      "no repair patch: no bridged producer's gomod2nix.toml pins v0.7.0"
      "godyn-go -- go mod tidy"
    ];
  };
}
