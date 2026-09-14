# go.nix — this module's dependencies (FDR 0008); go.mod, gomod2nix.toml and
# the package graph are rendered or derived from it inside nix. Edit through
# the escape hatch (godyn-go) or by hand.
{
  flakeInputs = {
    "example.com/dep" = {
      input = "dep";
      subPath = "dep";
    };
  };
  go = "1.26";
  module = "example.com/manifest";
  replace = { };
  require = {
    "github.com/google/go-cmp" = {
      go = "1.21";
      hash = "sha256-JbxZFBFGCh/Rj5XZ1vG94V2x7c18L8XKB0N9ZD5F2rM=";
      version = "v0.7.0";
    };
  };
}
