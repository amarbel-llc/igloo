# Dummy bun2nix binary for sandbox builds.
# Post-install scripts reference bun2nix, which can't run in the Nix sandbox.
{ pkgs }:

pkgs.writeShellApplication {
  name = "bun2nix";
  text = "";
}
