{ pkgs }:
let
  inherit (pkgs.callPackage ../../pkgs/build-support/gomod2nix/internals.nix { })
    mergeGomod2nixTomls;
in mergeGomod2nixTomls {
  consumer = {
    schema = 3;
    mod = {
      "github.com/example/shared" = { version = "v1.0.0"; hash = "consumer-hash"; };
      "github.com/example/only-in-consumer" = { version = "v2.0.0"; hash = "c"; };
    };
  };
  flakeInputs = [
    {
      schema = 3;
      mod = {
        "github.com/example/shared" = { version = "v0.9.0"; hash = "flake-hash"; };
        "github.com/example/only-in-flake" = { version = "v3.0.0"; hash = "f"; };
      };
    }
  ];
}
