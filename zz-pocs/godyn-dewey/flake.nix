{
  description = "godyn-dewey: D5 — build real dewey packages (cgo + bridge + lockfile) via the godyn per-package builder.";

  inputs = {
    # git+file (not path:) so nix copies only git-tracked files — the `path:`
    # form re-copies the whole worktree, including the gitignored ~2.6G .tmp
    # clone, on every eval (~38s). git+file skips .tmp entirely while still
    # seeing uncommitted tracked changes.
    igloo.url = "git+file:///home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany";

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

      # godyn-v2 native eval-time graph (one CA derivation per package, scheduled
      # by nix — no recursive-nix), built over the SAME internal/delta closure as
      # deweyDelta, for the real-scale head-to-head. The 74-package closure
      # exercises every ported compile-kind: zstd (cgo), x/sys + x/crypto (asm),
      # tommy (vendored — apples-to-apples with bga, not bridged), dewey (local).
      #
      # vendorEnv = buildGoApplication's gomod2nix vendor tree (committed
      # dewey-gomod2nix.toml snapshot of purse-first's workspace-root toml); only
      # .passthru.vendorEnv is forced, so dewey's mains never build here.
      deweyVendorEnv = (pkgs.buildGoApplication {
        pname = "dewey";
        version = "0";
        src = dewey-src;
        modules = ./dewey-gomod2nix.toml;
      }).passthru.vendorEnv;
      deweyDeltaNative = pkgs.callPackage ../godyn-v2/native.nix {
        inherit go stdlib;
        src = dewey-src;
        graphFile = ./dewey-delta-graph.json;
        vendorEnv = deweyVendorEnv;
        cc = pkgs.stdenv.cc;
        pname = "godyn-dewey-delta";
      };
      # #27 experiment: same build but local packages sourced straight from the
      # dewey-src flake input (lazySrc) instead of per-package builtins.path copies,
      # to measure whether builtins.path is what defeats lazy-trees. Trades
      # per-package incrementality for the lazy read (see native.nix lazySrc note).
      deweyDeltaNativeLazy = pkgs.callPackage ../godyn-v2/native.nix {
        inherit go stdlib;
        src = dewey-src;
        graphFile = ./dewey-delta-graph.json;
        vendorEnv = deweyVendorEnv;
        cc = pkgs.stdenv.cc;
        pname = "godyn-dewey-delta";
        lazySrc = true;
      };

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
        # #24: the lockfile scoped to this exact scope's graph (10 modules, vs the
        # full 55 in dewey.lock) so the resolver fetches only in-scope FODs. Regen
        # with `just gen-scoped-lock`. deweySeqerror/deweyAll keep dewey.lock.
        lockfile = ./dewey-delta.lock;
        packages = "./internal/delta/...";
        bridges = {
          "github.com/amarbel-llc/tommy" = tommyGoPkgs;
        };
        inherit stdlib;
      };

      # Same binary as purse-first's buildGoApplication `.#seqerror`, built
      # per-package — for an apples-to-apples godyn-vs-buildGoApplication edit
      # comparison on one target.
      deweySeqerror = mkDynamic {
        src = dewey-src;
        pname = "godyn-dewey-seqerror";
        lockfile = ./dewey.lock;
        packages = "./cmd/seqerror";
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
        dewey-seqerror = deweySeqerror.target;
        dewey-delta-wrapper = deweyDelta.wrapper;
        # Final: outputOf(wrapper) -> the compile-only manifest (the list of
        # compiled dewey/internal/delta packages; building it realises them all).
        dewey-delta = deweyDelta.target;
        # Approach A on the same closure: the native eval-time graph manifest.
        dewey-delta-native = deweyDeltaNative;
        dewey-delta-native-lazy = deweyDeltaNativeLazy;
        # The gomod2nix vendor tree native sources third-party packages from.
        # Exposed so `just bench-delta` can count its module FODs (the #24 metric:
        # after `just gen-scoped-toml` the toml is scoped to the graph, so this
        # fetches only the ~11 in-scope modules, not all 89 workspace modules).
        dewey-vendor-env = deweyVendorEnv;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          go
          pkgs.nix
          pkgs.jq
        ];
      };
    };
}
