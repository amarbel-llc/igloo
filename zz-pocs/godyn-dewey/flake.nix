{
  description = "godyn-dewey: D5 — build real dewey packages (cgo + bridge + lockfile) via the godyn per-package builder.";

  inputs = {
    # Absolute path: dodges pure-mode's /nix re-rooting (same as godyn-poc).
    igloo.url = "path:/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany";

    # dewey's source (the standalone libs/dewey module) and tommy's source,
    # both as non-flake path inputs into the gitignored .tmp clone — invisible
    # to igloo's dirty-tree build, so an absolute path input is the only route.
    dewey-src = {
      url = "path:/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany/.tmp/purse-first/libs/dewey";
      flake = false;
    };
    tommy-src = {
      url = "path:/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany/.tmp/purse-first/vendor/github.com/amarbel-llc/tommy";
      flake = false;
    };
  };

  outputs =
    {
      self,
      igloo,
      dewey-src,
      tommy-src,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = igloo.legacyPackages.${system};
      go = pkgs.go;

      # Reuse the godyn-poc engine: the shared stdlib + the extended resolver.
      stdlib = pkgs.callPackage ../godyn-poc/stdlib.nix { inherit go; };
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

      # tommy's RFC 0001 go-pkgs output (producer side) for the bridge.
      tommyGoPkgs = (pkgs.mkGoPkgs {
        src = tommy-src;
        name = "tommy";
      }).go-pkgs;

      # D5: dewey's internal/delta/... subtree — 18 dewey packages whose closure
      # exercises cgo (zstd via compression_type), the tommy bridge
      # (script_config, tommy_util -> cst/document/lexer/ringbuf), and ~36
      # third-party modules from the lockfile, in one godyn invocation. No main,
      # so it builds compile-only (every archive realised, no link). The full
      # ./... (169 own + hundreds of dep packages) is intentionally scoped out as
      # a serial-perf stress test — a throughput limit, not a capability gap.
      deweyDelta = mkDynamic {
        src = dewey-src;
        pname = "godyn-dewey-delta";
        lockfile = ./dewey.lock;
        packages = "./internal/delta/...";
        bridges = {
          "github.com/amarbel-llc/tommy" = tommyGoPkgs;
        };
        inherit stdlib;
      };

      # Full ./... — every dewey package (169 own + the full dep stack, ~400
      # packages incl. 4 analyzer mains). Throughput stress of the same pipeline;
      # has mains, so it links one binary + compiles the rest.
      deweyAll = mkDynamic {
        src = dewey-src;
        pname = "godyn-dewey-all";
        lockfile = ./dewey.lock;
        packages = "./...";
        bridges = {
          "github.com/amarbel-llc/tommy" = tommyGoPkgs;
        };
        inherit stdlib;
      };
    in
    {
      packages.${system} = {
        inherit stdlib;
        tommy-go-pkgs = tommyGoPkgs;
        # Intermediate wrapper (runs the resolver; $out is the manifest .drv).
        dewey-all = deweyAll.target;
        dewey-delta-wrapper = deweyDelta.wrapper;
        # Final: outputOf(wrapper) -> the compile-only manifest (the list of
        # compiled dewey/internal/delta packages; building it realises them all).
        dewey-delta = deweyDelta.target;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          go
          pkgs.nix
        ];
      };
    };
}
