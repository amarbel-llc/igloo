# Producer p as a go.nix module (FDR 0008): no tracked go.mod or gomod2nix.toml.
# mkGoPkgs renders both into its go-pkgs outputs and turns flakeInputs into
# passthru.goFlakeInputs, so consumers bridge it exactly like the organic p.
{
  module = "example.com/p";
  go = "1.26";
  flakeInputs."example.com/q".input = "q";
}
