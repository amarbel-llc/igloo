{
  description = "PoC: source a Go module dependency from a Nix flake input via go.mod replace.";

  inputs = {
    # Absolute path: `path:../..` gets re-rooted to the /nix/store copy of
    # this flake at eval time, not to the on-disk location, resolving to
    # /nix/ (forbidden in pure mode). Same workaround as rolldown-poc.
    nixpkgs.url = "path:/home/sasha/eng/repos/nixpkgs/.worktrees/sharp-cedar";

    # The "upstream Go library", consumed as a non-flake source. In the real
    # use case this would be e.g. github:owner/lib; here it points at the
    # ./upstream/ subdirectory of this PoC.
    poc-lib = {
      url = "path:./upstream";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      poc-lib,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.go
        ];
      };

      packages.${system} = {
        default = pkgs.callPackage ./default.nix {
          pocLibSrc = poc-lib;
        };
        via-gomod2nix = pkgs.callPackage ./default-via-gomod2nix.nix {
          pocLibSrc = poc-lib;
        };
        via-gomod2nix-race = pkgs.buildGoRace {
          base = self.packages.${system}.via-gomod2nix;
        };
        via-gomod2nix-overridden = self.packages.${system}.via-gomod2nix.overrideAttrs (_: {
          # No-op override; should not dislodge the merged-derivation closure.
          NIX_DEBUG = "0";
        });
        mkgoenv-test = pkgs.callPackage ./mkgoenv-test.nix {
          pocLibSrc = poc-lib;
        };
        mkgoenv-schema-only-test = pkgs.callPackage ./mkgoenv-schema-only-test.nix {
          pocLibSrc = poc-lib;
        };

        # Phase 7: verify goSourceFilter's return value passes the flake-schema
        # check for packages.<system>.<name>. Tracks amarbel-llc/nixpkgs#38 and
        # #43: before the fix, this builds fail with "expected ... a derivation
        # or path but found a set: { ... outPath = <thunk>; ... }". After the
        # fix (goSourceFilter returns a path), `nix build .#go-pkgs-test`
        # succeeds.
        go-pkgs-test = pkgs.goSourceFilter { src = ./upstream; };
      };
    };
}
