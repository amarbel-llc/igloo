{
  description = "godyn→godyn composition: module app (B) consuming module dep (A) via compiled-archive output (approach 1) vs source/go.mod (approach 2).";

  inputs.igloo.url = "git+file:///home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany";

  outputs =
    { self, igloo, ... }:
    let
      system = "x86_64-linux";
      pkgs = igloo.legacyPackages.${system};
      go = pkgs.go;
      stdlib = pkgs.callPackage ../godyn-poc/stdlib.nix { inherit go; };
      cross = pkgs.callPackage ./cross-native.nix {
        inherit go stdlib;
        depSrc = ./dep;
        appSrc = ./app;
      };
    in
    {
      packages.${system} = {
        inherit (cross) greetArchive greetAlt appBridge appSource;
      };
      devShells.${system}.default = pkgs.mkShell { packages = [ go pkgs.nix ]; };
    };
}
