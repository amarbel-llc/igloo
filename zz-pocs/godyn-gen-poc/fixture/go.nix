# Fixture module for godyn-gen-poc. Nothing generated is committed here: the
# pkgs/ facade (dagnabit) and the *_tommy.go companion (tommy) only exist in
# the derivations flake.nix builds.
{
  module = "example.com/gen";
  go = "1.26";
  flakeInputs."code.linenisgreat.com/tommy".input = "tommy";
}
