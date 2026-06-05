{
  description = "godyn v2 tracer bullet — eval-time native graph (A) vs recursive-nix resolver (B) vs buildGoApplication, built from one minimal Go module.";

  inputs = {
    # git+file (not path:) so nix copies only git-tracked files, never the
    # gitignored ~2.6G .tmp clone (the #25 fix). The in-repo module means a
    # source edit re-triggers naturally — no path:/lock gymnastics.
    igloo.url = "git+file:///home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany";
  };

  outputs =
    { self, igloo, ... }:
    let
      system = "x86_64-linux";
      pkgs = igloo.legacyPackages.${system};
      go = pkgs.go;
      stdlib = pkgs.callPackage ../godyn-poc/stdlib.nix { inherit go; };

      # A — eval-time native graph: one plain derivation per package, scheduled
      # by nix from the committed graph.json. No recursive-nix.
      native = pkgs.callPackage ./native.nix {
        inherit go stdlib;
        src = ./module;
        graphFile = ./graph.json;
      };

      # B — the existing recursive-nix resolver (godyn-poc), unchanged, on the
      # same module (pure-Go -> no lockfile). The current build-time-resolver
      # shape, for the apples-to-apples comparison.
      mkDynamic = import ../godyn-poc/dynamic.nix {
        inherit (pkgs)
          lib
          stdenv
          runCommandCC
          bash
          coreutils
          cacert
          nix
          ;
        inherit go;
        cc = pkgs.stdenv.cc;
      };
      recursive = (mkDynamic {
        src = ./module;
        pname = "godyntb";
        inherit stdlib;
      }).target;

      # Baseline — buildGoApplication (the nix whole-module builder godyn would
      # replace). No deps, so an empty gomod2nix.toml.
      bga = pkgs.buildGoApplication {
        pname = "godyntb";
        version = "0";
        src = ./module;
        modules = ./module/gomod2nix.toml;
      };
    in
    {
      packages.${system} = {
        inherit
          native
          recursive
          bga
          stdlib
          ;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          go
          pkgs.nix
        ];
      };
    };
}
