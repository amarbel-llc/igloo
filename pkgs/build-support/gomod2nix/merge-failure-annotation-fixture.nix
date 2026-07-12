# Negative fixture for amarbel-llc/igloo#55 — its build is EXPECTED TO FAIL.
# NOT named `*-test.nix` on purpose: the success-only `test-gomod2nix` glob
# must not pick it up. Driven by the `test-gomod2nix-merge-annotation`
# justfile recipe, which builds this, asserts a nonzero exit, and greps the
# annotated failure message out of stderr.
#
# The failure: the consumer's own go.mod carries an invalid organic require
# for a bridged /v2 module (a v0 pseudo-version on a /v2 path). foo/v2 is
# organically required, so mkMergedGoMod's conditional-require path keeps the
# organic version and emits only the `-replace`; `go mod edit -replace`
# re-validates the whole modfile and rejects the invalid require
# ("should be v2, not v0"), driving the annotated bridge failure handler.
{
  pkgs ? import ../../.. { },
}:
let
  inherit (pkgs.callPackage ./internals.nix { }) mkMergedGoMod;

  # go mod edit -replace does not require the target to exist on disk.
  fooV2Src = pkgs.runCommand "foo-v2-src" { } "mkdir -p $out";

  consumerGoMod = pkgs.writeText "bad-consumer-go.mod" ''
    module example.com/consumer

    go 1.26

    require example.com/foo/v2 v0.0.0-00010101000000-000000000000
  '';
in
mkMergedGoMod {
  inherit consumerGoMod;
  go = pkgs.go;
  runCommand = pkgs.runCommand;
  goFlakeInputs = {
    "example.com/foo/v2" = fooV2Src;
  };
  # Organically required -> conditional-require keeps the (invalid) organic
  # version and emits only the -replace, whose re-validation fails.
  consumerRequires = [ "example.com/foo/v2" ];
}
