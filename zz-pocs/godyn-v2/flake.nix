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
      recursive =
        (mkDynamic {
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

      # Real-module scale-up: tommy's pure-Go library (7 packages,
      # ringbuf -> lexer -> cst -> document -> marshal, + formatter), a snapshot
      # of github.com/amarbel-llc/tommy's library subtree. Same three approaches.
      tommy-native = pkgs.callPackage ./native.nix {
        inherit go stdlib;
        src = ./tommy-lib;
        graphFile = ./tommy-graph.json;
        pname = "tommy";
      };
      tommy-recursive =
        (mkDynamic {
          src = ./tommy-lib;
          pname = "tommy";
          inherit stdlib;
        }).target;
      tommy-bga = pkgs.buildGoApplication {
        pname = "tommy";
        version = "0";
        src = ./tommy-lib;
        modules = ./tommy-lib/gomod2nix.toml;
      };

      # buildGoAuto: dispatch native (dev loop) vs buildGoApplication (cold/CI)
      # by `strategy`. Both backends reachable via passthru.{native,bga}.
      buildGoAuto = args: pkgs.callPackage ./selector.nix ({ inherit go stdlib; } // args);
      tommyAutoArgs = {
        pname = "tommy";
        src = ./tommy-lib;
        graphFile = ./tommy-graph.json;
        modules = ./tommy-lib/gomod2nix.toml;
      };
      tommy-auto = buildGoAuto (tommyAutoArgs // { strategy = "dev"; }); # -> native
      tommy-auto-ci = buildGoAuto (tommyAutoArgs // { strategy = "ci"; }); # -> bga

      # cgo validation: the v1 toy-cgo (DataDog/zstd round-trip) built native.
      # zstd is a third-party CGO package (C source + CgoFiles), sourced from the
      # gomod2nix vendorEnv; the main links externally (-extld). Exercises the
      # ported cgo path end to end before the dewey scale-up.
      cgo-test-bga = pkgs.buildGoApplication {
        pname = "godyn-cgo";
        version = "0";
        src = ./cgo-test;
        modules = ./cgo-test/gomod2nix.toml;
      };
      cgo-test-native = pkgs.callPackage ./native.nix {
        inherit go stdlib;
        src = ./cgo-test;
        graphFile = ./cgo-test-graph.json;
        vendorEnv = cgo-test-bga.passthru.vendorEnv;
        cc = pkgs.stdenv.cc;
        pname = "godyn-cgo";
      };

      # asm validation: an all-local module (no third-party, no cgo, no cc) whose
      # asmpkg has a hand-written amd64 Plan 9 .s — isolates the ported asmScript
      # (gensymabis → compile -symabis -asmhdr → assemble → pack) with zero
      # network. Binary must print Add(19,23)=42.
      asm-test-native = pkgs.callPackage ./native.nix {
        inherit go stdlib;
        src = ./asm-test;
        graphFile = ./asm-test-graph.json;
        pname = "godyn-asm";
      };

      # godyn TEST-SUPPORT POC: per-package `go test` on the eval-time graph.
      # leaf (in-package + external tests) + mid (imports leaf). Proves the
      # merkle-delta extends to tests — only the changed cone's tests re-run.
      testPoc = pkgs.callPackage ./test-native.nix {
        inherit go stdlib;
        src = ./test-poc;
      };
    in
    {
      packages.${system} = {
        inherit
          native
          recursive
          bga
          stdlib
          tommy-native
          tommy-recursive
          tommy-bga
          tommy-auto
          tommy-auto-ci
          cgo-test-native
          cgo-test-bga
          asm-test-native
          ;
        test-poc-leaf = testPoc.leafTest;
        test-poc-mid = testPoc.midTest;
        test-poc-all = testPoc.checkAll;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          go
          pkgs.nix
        ];
      };
    };
}
