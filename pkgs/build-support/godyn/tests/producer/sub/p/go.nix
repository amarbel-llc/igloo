# Producer p as a go.nix module living in a SUBDIRECTORY of the published tree
# (FDR 0008; crap's go-crap/ shape): mkGoPkgs { src = <sub>; subPath = "p"; }
# renders go.mod and gomod2nix.toml at go-pkgs/p/, where consumers bridging
# with subPath "p" expect them.
{
  module = "example.com/p";
  go = "1.26";
  flakeInputs."example.com/q".input = "q";
}
