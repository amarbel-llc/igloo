{
  description = "amarbel-llc/igloo — overlay flake providing Nix build-support helpers, pins, and package additions on top of nixpkgs.";

  inputs = {
    nixpkgs-master.url = "github:NixOS/nixpkgs/567a49d1913ce81ac6e9582e3553dd90a955875f";

    # Declared at top level only so bun2nix's transitive copies can
    # follow these and collapse to single nodes in downstream locks.
    # Not consumed by this flake's outputs.
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs-master";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs-master";

    # bun2nix — only needed for its CLI binary, which the bun2nix-lint
    # stack regen / drift-guard plumbing wraps. The Nix library
    # functions and the cacheEntryCreator Zig binary live under
    # pkgs/build-support/bun2nix/ in-tree.
    bun2nix.url = "github:nix-community/bun2nix";
    bun2nix.inputs.nixpkgs.follows = "nixpkgs-master";
    bun2nix.inputs.flake-parts.follows = "flake-parts";
    bun2nix.inputs.systems.follows = "systems";
    bun2nix.inputs.treefmt-nix.follows = "treefmt-nix";

  };

  outputs =
    { self, nixpkgs-master, bun2nix, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs-master.lib.genAttrs systems;
    in
    {
      lib = nixpkgs-master.lib;

      overlays = {
        default = nixpkgs-master.lib.composeManyExtensions (import ./overlays nixpkgs-master.lib);
        amarbelPackages = import ./overlays/amarbel-packages.nix;
      };

      legacyPackages = forAllSystems (
        system:
        import nixpkgs-master {
          inherit system;
          overlays = [ self.overlays.default ];
          config.allowUnfree = true;
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
        in
        {
          inherit (pkgs)
            claude-code
            gomod2nix
            gomod2nix-man
            update-zx-deps
            ;
          nix-man = pkgs.nix.man;
          default = pkgs.claude-code;

          # -- godyn build-test fixtures --
          # Exercise buildGodynModule's two productionization features end to end:
          # go:embed (-embedcfg) and -ldflags version stamping. Built as packages so
          # `nix build .#godyn-{embed,ldflags}-test` produces a runnable binary; the
          # checks below assert their output.
          inherit (pkgs) godyn-gen nixgc;
          godyn-embed-test = pkgs.buildGodynModule {
            pname = "godyn-embed-test";
            src = ./pkgs/build-support/godyn/tests/embed;
            graphFile = ./pkgs/build-support/godyn/tests/embed/graph.json;
          };
          godyn-ldflags-test = pkgs.buildGodynModule {
            pname = "godyn-ldflags-test";
            src = ./pkgs/build-support/godyn/tests/ldflags;
            graphFile = ./pkgs/build-support/godyn/tests/ldflags/graph.json;
            # No explicit version -> version.env (9.9.9) is auto-read; commit falls
            # back to "unknown" (the path src has no rev); channel via the structured
            # ldflagsX convenience.
            ldflagsX = {
              "main.channel" = "stable";
            };
          };
          # buildGoAuto dispatch: strategy="native" -> buildGodynModule. The check
          # below builds + runs it (proving the godyn backend was selected); both
          # backends stay reachable via passthru.{native,bga}.
          godyn-selector-test = pkgs.buildGoAuto {
            pname = "godyn-embed-test";
            src = ./pkgs/build-support/godyn/tests/embed;
            graphFile = ./pkgs/build-support/godyn/tests/embed/graph.json;
            strategy = "native";
          };
          # graphFiles (per-system graphs, igloo#33): the same embed fixture with its
          # graph supplied via the per-system attrset — exercises the selection path.
          # The fixture is platform-independent, so the one graph is valid for the
          # evaluating system.
          godyn-graphfiles-test = pkgs.buildGodynModule {
            pname = "godyn-embed-test";
            src = ./pkgs/build-support/godyn/tests/embed;
            graphFiles.${system} = ./pkgs/build-support/godyn/tests/embed/graph.json;
          };
          # go test support (igloo#32): a library fixture whose tests cover the
          # in-package / external / TestMain / Example / go:embed / testdata /
          # test-only-dep cases. The package is the manifest terminal; the check
          # below realises passthru.checkAll (every per-package test run).
          godyn-gotest-test = pkgs.buildGodynModule {
            pname = "godyn-gotest-test";
            src = ./pkgs/build-support/godyn/tests/gotest;
            graphFile = ./pkgs/build-support/godyn/tests/gotest/godyn-graph.json;
            testGraphFile = ./pkgs/build-support/godyn/tests/gotest/godyn-test-graph.json;
          };
          # string-typed src regression (dir "." filter, the eng/conformist
          # incident — mechanism documented at pkgRootFor in build-godyn-module.nix):
          # flake inputs provide src as a store-path STRING, a shape the
          # path-literal fixtures above can't represent. gotest's root package
          # covers the test-graph (relTo) side.
          godyn-string-src-test = pkgs.buildGodynModule {
            pname = "godyn-embed-test";
            src = "${./pkgs/build-support/godyn/tests/embed}";
            graphFile = ./pkgs/build-support/godyn/tests/embed/graph.json;
          };
          godyn-string-src-gotest-test = pkgs.buildGodynModule {
            pname = "godyn-gotest-test";
            src = "${./pkgs/build-support/godyn/tests/gotest}";
            graphFile = ./pkgs/build-support/godyn/tests/gotest/godyn-graph.json;
            testGraphFile = ./pkgs/build-support/godyn/tests/gotest/godyn-test-graph.json;
          };

          # -- godyn cross-module fixtures (godyn→godyn composition) --
          # dep (A, example.com/dep) is built once; app (B, example.com/app) consumes
          # it two ways from the SAME app graph: source (bridges → A compiled in B's
          # graph, approach 2) and pre-built archive (archiveBridges → A's
          # passthru.archiveGoPkgs linked, not recompiled, approach 1). The checks
          # below assert both binaries print the cross-module call's output.
          godyn-cross-source = pkgs.buildGodynModule {
            pname = "godyn-cross-app";
            src = ./pkgs/build-support/godyn/tests/cross/app;
            graphFile = ./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json;
            bridges = {
              "example.com/dep" = ./pkgs/build-support/godyn/tests/cross/dep;
            };
          };
          godyn-cross-archive =
            let
              dep = pkgs.buildGodynModule {
                pname = "godyn-cross-dep";
                src = ./pkgs/build-support/godyn/tests/cross/dep;
                graphFile = ./pkgs/build-support/godyn/tests/cross/dep/godyn-graph.json;
              };
            in
            pkgs.buildGodynModule {
              pname = "godyn-cross-app";
              src = ./pkgs/build-support/godyn/tests/cross/app;
              graphFile = ./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json;
              archiveBridges = {
                "example.com/dep" = dep.passthru.archiveGoPkgs;
              };
            };

          # -- bun2nix test fixtures --
          # Exercise buildBunBinary / buildZxScript / buildZxScriptFromFile
          # against pinned source trees so the surface area is build-tested
          # on every flake check. Lint-relevant fixtures are also referenced
          # by the lint-rejects-process-exit smoke check below.

          test-zx-basic = pkgs.buildZxScript {
            pname = "test-zx-basic";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/zx-basic;
          };

          test-zx-extra-deps = pkgs.buildZxScript {
            pname = "test-zx-extra-deps";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/zx-extra-deps;
            extraDeps = {
              "chalk@5.4.1" = pkgs.fetchurl {
                url = "https://registry.npmjs.org/chalk/-/chalk-5.4.1.tgz";
                hash = "sha512-zgVZuo2WcZgfUEmsn6eO3kINexW8RAE4maiQ8QNs8CtpPCSyMiYsULR3HQYkm3w8FIA3SberyMJMSldGsW+U3w==";
              };
            };
          };

          test-zx-from-file = pkgs.buildZxScriptFromFile {
            pname = "test-zx-from-file";
            version = "0.0.1";
            script = ./pkgs/build-support/bun2nix/tests/zx-from-file/index.ts;
          };

          # Lint passes: `process.exitCode = N; return;` (the recommended pattern).
          test-bin-no-process-exit = pkgs.buildBunBinary {
            pname = "test-bin-no-process-exit";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/bin-no-process-exit;
          };

          # Lint passes: `process.exit()` allowed via inline eslint-disable.
          test-bin-process-exit-disabled = pkgs.buildBunBinary {
            pname = "test-bin-process-exit-disabled";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/bin-process-exit-disabled;
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          bun2nixCli = bun2nix.packages.${system}.bun2nix;
          regenLintStack = import ./pkgs/build-support/bun2nix/lint/regen.nix {
            inherit pkgs;
            bun = pkgs.bun;
            bun2nix = bun2nixCli;
          };
          benchBunStartup = import ./pkgs/build-support/bun2nix/bench/bench-bun-startup.nix {
            inherit pkgs;
          };
        in
        {
          regen-bun2nix-lint-stack = {
            type = "app";
            program = "${regenLintStack}/bin/regen-bun2nix-lint-stack";
          };
          bench-bun-startup = {
            type = "app";
            program = "${benchBunStartup}/bin/bench-bun-startup";
          };
          update-zx-deps = {
            type = "app";
            program = "${pkgs.update-zx-deps}/bin/update-zx-deps";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          bun2nixCli = bun2nix.packages.${system}.bun2nix;
        in
        {
          claude-code = pkgs.claude-code;
          gomod2nix = pkgs.gomod2nix;
          gomod2nix-man = pkgs.gomod2nix-man;
          godyn-man = pkgs.godyn-man;
          nixgc-man = pkgs.nixgc-man;
          nix-man = pkgs.nix.man;

          bun2nix-lint-stack-up-to-date = import ./pkgs/build-support/bun2nix/lint/check.nix {
            inherit pkgs;
            bun2nix = bun2nixCli;
            bunLock = ./pkgs/build-support/bun2nix/lint/bun.lock;
            bunNix = ./pkgs/build-support/bun2nix/lint/bun.nix;
          };

          # Smoke check: confirm the lint stack actually fires on a
          # known-bad fixture. Targets `.passthru.lint` because
          # `testBuildFailure'` can only catch failures from the
          # wrapped derivation's own builder — failures in the lint
          # derivation cascade past the wrapper and bundle.
          bun2nix-lint-stack-rejects-process-exit = pkgs.testers.testBuildFailure' {
            drv =
              (pkgs.buildBunBinary {
                pname = "test-bin-process-exit-fail";
                version = "0.0.1";
                src = ./pkgs/build-support/bun2nix/tests/bin-process-exit-fail;
              }).passthru.lint;
            expectedBuilderLogEntries = [ "n/no-process-exit" ];
          };

          # Echo bun2nix fixtures as checks so flake check builds them.
          inherit (self.packages.${system})
            test-zx-basic
            test-zx-extra-deps
            test-zx-from-file
            test-bin-no-process-exit
            test-bin-process-exit-disabled
            ;

          # godyn: run the fixture binaries and assert their output, so a regression
          # in the go:embed (-embedcfg) or ldflags (-X) path fails the pre-merge hook.
          godyn-embed-test = pkgs.runCommandLocal "godyn-embed-test-check" { } ''
            got=$(${self.packages.${system}.godyn-embed-test}/bin/godyn-embed-test)
            want="godyn embed works"
            [ "$got" = "$want" ] || { echo "embed mismatch: got [$got] want [$want]" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-ldflags-test = pkgs.runCommandLocal "godyn-ldflags-test-check" { } ''
            got=$(${self.packages.${system}.godyn-ldflags-test}/bin/godyn-ldflags-test)
            want="version=9.9.9 commit=unknown channel=stable"
            [ "$got" = "$want" ] || { echo "ldflags mismatch: got [$got] want [$want]" >&2; exit 1; }
            echo OK > $out
          '';
          # buildGoAuto picked the native (godyn) backend; its binary runs.
          godyn-selector-test = pkgs.runCommandLocal "godyn-selector-test-check" { } ''
            got=$(${self.packages.${system}.godyn-selector-test}/bin/godyn-embed-test)
            [ "$got" = "godyn embed works" ] || { echo "selector native mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          # per-system graph selection (graphFiles, igloo#33): the graph resolved via
          # graphFiles.''${system} builds a working binary.
          godyn-graphfiles-test = pkgs.runCommandLocal "godyn-graphfiles-test-check" { } ''
            got=$(${self.packages.${system}.godyn-graphfiles-test}/bin/godyn-embed-test)
            [ "$got" = "godyn embed works" ] || { echo "graphFiles mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          # go test (igloo#32): checkAll realises every per-package test run (a
          # failing test fails this check); assert both packages reported.
          godyn-gotest-test = pkgs.runCommandLocal "godyn-gotest-test-check" { } ''
            res=${self.packages.${system}.godyn-gotest-test.passthru.checkAll}
            grep -qx "ok example.com/gotest/leaf" "$res" || { echo "missing leaf result" >&2; cat "$res" >&2; exit 1; }
            grep -qx "ok example.com/gotest/mid" "$res" || { echo "missing mid result" >&2; cat "$res" >&2; exit 1; }
            grep -qx "ok example.com/gotest" "$res" || { echo "missing root result" >&2; cat "$res" >&2; exit 1; }
            echo OK > $out
          '';
          # string-typed src (dir "." filter regression, see pkgRootFor): a filter
          # break makes these BUILDS fail (empty filtered srcDir → no such file),
          # and the path-literal siblings above already run the same binaries/tests
          # on what dedupes to identical store paths — so realising the build is
          # the whole assertion; no run-and-compare wrapper needed.
          godyn-string-src-test = self.packages.${system}.godyn-string-src-test;
          godyn-string-src-gotest-test = self.packages.${system}.godyn-string-src-gotest-test.passthru.checkAll;
          # godyn→godyn composition: both consumption modes must produce a working
          # binary from the same app graph. (Source = bridges; archive = archiveBridges.)
          godyn-cross-source = pkgs.runCommandLocal "godyn-cross-source-check" { } ''
            got=$(${self.packages.${system}.godyn-cross-source}/bin/godyn-cross-app)
            [ "$got" = "hello from dep/greet" ] || { echo "bridges (source) mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-cross-archive = pkgs.runCommandLocal "godyn-cross-archive-check" { } ''
            got=$(${self.packages.${system}.godyn-cross-archive}/bin/godyn-cross-app)
            [ "$got" = "hello from dep/greet" ] || { echo "archiveBridges (output) mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
        in
        {
          bun-dev = pkgs.mkBunDevShell { };
        }
      );

      nixosModules = nixpkgs-master.nixosModules;
    };
}
