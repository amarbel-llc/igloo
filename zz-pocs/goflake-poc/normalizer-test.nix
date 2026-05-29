# Test: normalizeFlakeInput accepts both shapes
{ pkgs }:
let
  inherit (pkgs.callPackage ../../pkgs/build-support/gomod2nix/internals.nix { })
    normalizeFlakeInput;
in
{
  bareDrv = normalizeFlakeInput ./.;
  # Expected: { src = ./.; subPath = ""; }

  attrsForm = normalizeFlakeInput {
    src = pkgs.hello;
    subPath = "go";
  };
  # Expected: { src = pkgs.hello; subPath = "go"; }
}
