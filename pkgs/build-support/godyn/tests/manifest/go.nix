# The manifest fixture's only module description (FDR 0008): its go.mod, its
# gomod2nix.toml and its package graph are all rendered or derived from this file.
{
  module = "example.com/manifest";
  go = "1.26";
  require."github.com/google/go-cmp" = {
    version = "v0.6.0";
    hash = "sha256-qgra5jze4iPGP0JSTVeY5qV5AvEnEu39LYAuUCIkMtg=";
    go = "1.13";
  };
  flakeInputs."example.com/dep" = {
    input = "dep";
    subPath = "dep";
  };
}
