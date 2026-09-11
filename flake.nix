{
  description = "amarbel-llc/igloo — overlay flake providing Nix build-support helpers, pins, and package additions on top of nixpkgs.";

  inputs = {
    nixpkgs-master.url = "github:NixOS/nixpkgs/f13ff45afd1bb73e640eaa08a7066dbed07e3238";

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
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs-master";
        flake-parts.follows = "flake-parts";
        systems.follows = "systems";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

  };

  outputs =
    {
      self,
      nixpkgs-master,
      bun2nix,
      # Formally named so flake-outputs linter passes; not consumed by
      # igloo's outputs — declared only for downstream follows collapse.
      flake-parts,
      systems,
      treefmt-nix,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs-master.lib.genAttrs supportedSystems;

      # Fixed-output source fetch for conformist. igloo is strictly upstream of
      # conformist (conformist.inputs.igloo), so a flake input here would close a
      # cycle. This FOD leaf pins conformist by commit + hash and pulls no flake
      # graph — the same pattern conformist itself uses for purse-first's dewey
      # plugin to avoid an analogous cycle (see conformist's AGENTS.md §"flake
      # outputs" and its golangciLintDeweySrc FOD).
      #
      # To bump: re-prefetch with the new commit SHA, update rev + hash:
      #   nix-prefetch-git --url https://code.linenisgreat.com/conformist.git --rev <new-sha>
      # or use a deliberate wrong-hash nix build to get the correct SRI hash
      # from the error output.
      mkConformist =
        pkgs:
        let
          conformistSrc = pkgs.fetchgit {
            url = "https://code.linenisgreat.com/conformist.git";
            rev = "025c839dda59e4ff47249e56ea636d7cc262b604"; # v0.1.19
            hash = "sha256-Ac2CID8/oe4WAsedvfTpjQMjoduKTglJaKraqoczTT0=";
          };
          # conformist's Nix module library — a pure Nix file with no flake
          # dependency; import directly from the FOD store path.
          conformistLib = import "${conformistSrc}/nix";
          # No explicit `version`: conformist carries a version.env at its
          # source root, and buildGoApplication (gomod2nix default.nix,
          # eng-versioning(7) § VERSION EMBEDDING) auto-reads it via `pwd`
          # (== src here) as the single source of truth for both the
          # derivation `version` attr and the `-X main.version` ldflag. A
          # hardcoded version here previously drifted from conformist's
          # actual version.env (0.1.17 vs 0.1.18) — this can't drift again.
          conformistBin = pkgs.buildGoApplication {
            pname = "conformist";
            src = conformistSrc;
            pwd = conformistSrc;
            modules = "${conformistSrc}/gomod2nix.toml";
            subPackages = [ "." ];
            inherit (pkgs) go;
            GOTOOLCHAIN = "local";
            doCheck = false;
          };
          conformistEval = conformistLib.evalModule pkgs {
            imports = [
              conformistLib.presets.eng
              ./conformist.nix
            ];
            package = conformistBin;
          };
          conformistImpureEval = conformistLib.evalModule pkgs {
            imports = [
              conformistLib.presets.eng-impure
              ./conformist-impure.nix
            ];
            package = conformistBin;
          };
        in
        {
          inherit
            conformistSrc
            conformistLib
            conformistBin
            conformistEval
            conformistImpureEval
            ;
        };
    in
    {
      inherit (nixpkgs-master) lib;

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

      formatter = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          c = mkConformist pkgs;
        in
        c.conformistEval.config.build.wrapper
      );

      packages = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          c = mkConformist pkgs;
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

          conformist = c.conformistBin;
          conformist-impure-config = c.conformistImpureEval.config.build.configFile;
          conformist-pre-commit = c.conformistEval.config.build.preCommit;
          conformist-repair = c.conformistEval.config.build.repair;

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
          # go:embed beyond literal files (igloo#68): a mid-path glob and a
          # directory pattern, resolved per pattern by godyn-gen.
          godyn-embed-glob-test = pkgs.buildGodynModule {
            pname = "godyn-embed-glob-test";
            src = ./pkgs/build-support/godyn/tests/embed-glob;
            graphFile = ./pkgs/build-support/godyn/tests/embed-glob/graph.json;
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
          # buildGoAuto goFlakeInputs (igloo#69): the bridge declared once in RFC 0001
          # { src; subPath; } form must reach the godyn backend as `bridges`, with
          # subPath folded into the path (godyn's bridges have no subPath knob).
          godyn-auto-goflakeinputs-test = pkgs.buildGoAuto {
            pname = "godyn-cross-app";
            src = ./pkgs/build-support/godyn/tests/cross/app;
            graphFile = ./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json;
            goFlakeInputs = {
              "example.com/dep" = {
                src = ./pkgs/build-support/godyn/tests/cross;
                subPath = "dep";
              };
            };
            strategy = "native";
          };
          # buildGoAuto install step, declared once for both backends: runs the
          # just-built binary, reads the source tree (cwd), uses a nativeBuildInput,
          # and adds an alias symlink. Binary names differ per backend, so glob.
          godyn-auto-postinstall-test = pkgs.buildGoAuto {
            pname = "godyn-cross-app";
            src = ./pkgs/build-support/godyn/tests/cross/app;
            graphFile = ./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json;
            goFlakeInputs = {
              "example.com/dep" = {
                src = ./pkgs/build-support/godyn/tests/cross;
                subPath = "dep";
              };
            };
            # explicit version: without it the bga backend fails eval on this
            # modules-less fixture ("attribute 'name' missing", igloo#70).
            version = "0.0.0";
            nativeBuildInputs = [ pkgs.jq ];
            postInstall = ''
              mkdir -p "$out/share"
              for b in "$out"/bin/*; do "$b" > "$out/share/greeting"; done
              cp go.mod "$out/share/go.mod"
              jq -n '"ok"' > "$out/share/jq"
              ln -s "$(basename "$(ls "$out"/bin/* | head -n1)")" "$out/bin/alias"
            '';
            strategy = "native";
          };
          # No committed graph (FDR 0008, igloo#72): the cross/app module built with
          # its graph derived at eval time from gomod2nix.toml + goFlakeInputs.
          godyn-derived-graph-test = pkgs.buildGodynModule {
            pname = "godyn-cross-app";
            src = ./pkgs/build-support/godyn/tests/cross/app;
            modules = ./pkgs/build-support/godyn/tests/cross/app/gomod2nix.toml;
            goFlakeInputs."example.com/dep" = {
              src = ./pkgs/build-support/godyn/tests/cross;
              subPath = "dep";
            };
            version = "0.0.0";
          };
          # No committed graphs at all: the gotest fixture with both its build and
          # test graphs derived at eval time (tests = true).
          godyn-derived-tests-test = pkgs.buildGodynModule {
            pname = "godyn-gotest-test";
            src = ./pkgs/build-support/godyn/tests/gotest;
            modules = ./pkgs/build-support/godyn/tests/gotest/gomod2nix.toml;
            tests = true;
          };
          # Go language version: the module declares go 1.21 (pre-loopvar), built
          # through both backends; see the godyn-lang-test check.
          godyn-lang-test = pkgs.buildGoAuto {
            pname = "godyn-lang-test";
            src = ./pkgs/build-support/godyn/tests/lang;
            graphFile = ./pkgs/build-support/godyn/tests/lang/graph.json;
            version = "0.0.0"; # igloo#70
            strategy = "native";
          };
          # cgo: a C-backed package imported by main — the cgo compile path, and the
          # analysis lanes over cgo packages (igloo#71).
          godyn-cgo-test = pkgs.buildGodynModule {
            pname = "godyn-cgo-test";
            src = ./pkgs/build-support/godyn/tests/cgo;
            graphFile = ./pkgs/build-support/godyn/tests/cgo/graph.json;
            cc = pkgs.stdenv.cc;
          };
          # per-package lint (godyn-lint): package bad carries an unsuppressed
          # staticcheck finding, package ok the same one under //nolint.
          godyn-lint-test = pkgs.buildGodynModule {
            pname = "godyn-lint-test";
            src = ./pkgs/build-support/godyn/tests/lint;
            graphFile = ./pkgs/build-support/godyn/tests/lint/graph.json;
          };
          # per-package vet: a printf misuse through a wrapper in another package,
          # visible only through that package's vet facts.
          godyn-vet-test = pkgs.buildGodynModule {
            pname = "godyn-vet-test";
            src = ./pkgs/build-support/godyn/tests/vet;
            graphFile = ./pkgs/build-support/godyn/tests/vet/graph.json;
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
            inherit (pkgs) bun;
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
          c = mkConformist pkgs;
          gocheck = import ./zz-pocs/gocheck-poc { inherit pkgs; };
        in
        {
          formatting = c.conformistEval.config.build.check self;

          inherit (pkgs) claude-code;
          inherit (pkgs) gomod2nix;
          inherit (pkgs) gomod2nix-man;
          inherit (pkgs) go-toolchain-man;
          inherit (pkgs) godyn-man;
          inherit (pkgs) nixgc-man;
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
          # igloo#68: every pattern embeds its files — the templates glob (not
          # ignore.txt) and the static tree minus its dot-file.
          godyn-embed-glob-test = pkgs.runCommandLocal "godyn-embed-glob-test-check" { } ''
            got=$(${self.packages.${system}.godyn-embed-glob-test}/bin/godyn-embed-glob-test)
            want=$(printf 'alpha\nbeta\nstatic/sub/y.txt\nstatic/x.txt')
            [ "$got" = "$want" ] || { echo "embed-glob mismatch: got [$got] want [$want]" >&2; exit 1; }
            echo OK > $out
          '';
          # igloo#68 fail-loud: the same fixture with its graph stripped back to the
          # pre-mapping shape must refuse to evaluate, not build a binary whose
          # embed.FS is empty.
          godyn-embed-legacy-throws =
            let
              legacyGraph = builtins.toFile "godyn-embed-glob-legacy.json" (
                builtins.toJSON (
                  map (p: removeAttrs p [ "embedPatternFiles" ]) (
                    builtins.fromJSON (builtins.readFile ./pkgs/build-support/godyn/tests/embed-glob/graph.json)
                  )
                )
              );
              attempt =
                builtins.tryEval
                  (pkgs.buildGodynModule {
                    pname = "godyn-embed-glob-test";
                    src = ./pkgs/build-support/godyn/tests/embed-glob;
                    graphFile = legacyGraph;
                  }).drvPath;
            in
            assert !attempt.success;
            pkgs.runCommandLocal "godyn-embed-legacy-throws" { } "echo OK > $out";
          # igloo#67: `godyn-gen -gomod` resolves a bridged module through the merged
          # go.mod buildGoApplication produces for the same goFlakeInputs — the file
          # godyn(7) tells consumers to pass. The fixture app's tracked replace is
          # pointed at a missing dir, so gen must fail without -gomod, and with it
          # must reproduce the committed graph byte for byte while leaving the
          # tracked go.mod untouched.
          godyn-gen-gomod-test =
            pkgs.runCommandLocal "godyn-gen-gomod-test"
              {
                nativeBuildInputs = [
                  pkgs.go
                  pkgs.godyn-gen
                ];
              }
              ''
                export HOME=$TMPDIR GOCACHE=$TMPDIR/gocache GOPATH=$TMPDIR/gopath
                export GOPROXY=off GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=0
                cp -r ${./pkgs/build-support/godyn/tests/cross/app} app
                chmod -R u+w app
                sed -i 's|=> ../dep|=> ./missing-dep|' app/go.mod
                if godyn-gen app no-gomod.json 2>/dev/null; then
                  echo "godyn-gen resolved the broken replace without -gomod" >&2; exit 1
                fi
                godyn-gen -gomod ${
                  self.packages.${system}.godyn-auto-goflakeinputs-test.passthru.bga.passthru.mergedGoMod
                } app got.json
                diff -u ${./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json} got.json
                grep -q missing-dep app/go.mod
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
          inherit (self.packages.${system}) godyn-string-src-test;
          godyn-string-src-gotest-test =
            self.packages.${system}.godyn-string-src-gotest-test.passthru.checkAll;
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
          godyn-auto-goflakeinputs-test = pkgs.runCommandLocal "godyn-auto-goflakeinputs-test-check" { } ''
            got=$(${self.packages.${system}.godyn-auto-goflakeinputs-test}/bin/godyn-cross-app)
            [ "$got" = "hello from dep/greet" ] || { echo "buildGoAuto goFlakeInputs mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-auto-postinstall-test =
            let
              auto = self.packages.${system}.godyn-auto-postinstall-test;
            in
            pkgs.runCommandLocal "godyn-auto-postinstall-test-check" { } ''
              for pkg in ${auto.passthru.native} ${auto.passthru.bga}; do
                [ "$(cat "$pkg/share/greeting")" = "hello from dep/greet" ] || { echo "$pkg: postInstall did not run the binary" >&2; exit 1; }
                grep -q '^module example.com/app' "$pkg/share/go.mod" || { echo "$pkg: postInstall cwd is not the source tree" >&2; exit 1; }
                [ "$(cat "$pkg/share/jq")" = '"ok"' ] || { echo "$pkg: nativeBuildInputs not on PATH" >&2; exit 1; }
                "$pkg/bin/alias" > /dev/null || { echo "$pkg: alias symlink broken" >&2; exit 1; }
              done
              echo OK > $out
            '';
          # per-package vet: the misuse of logf.Logf in main is only detectable from
          # the logf package's printf facts, so this failure proves facts chain from
          # one package's vet derivation to its dependents'.
          godyn-vet-facts-test = pkgs.testers.testBuildFailure' {
            drv = self.packages.${system}.godyn-vet-test.passthru.vet."example.com/vet";
            expectedBuilderLogEntries = [ "Logf format %d has arg" ];
          };
          # a clean multi-package module vets green (gotest: local cross-package
          # imports), and a bridged dependency is vetted facts-only.
          godyn-vet-clean-test = self.packages.${system}.godyn-gotest-test.passthru.vetAll;
          godyn-vet-bridged-test = self.packages.${system}.godyn-cross-source.passthru.vetAll;
          # eval-time graph: the derived-graph build runs, and its graph equals the
          # committed one godyn-gen -gomod produced for the same module.
          godyn-derived-graph-test =
            let
              derived = self.packages.${system}.godyn-derived-graph-test;
            in
            pkgs.runCommandLocal "godyn-derived-graph-test-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              got=$(${derived}/bin/godyn-cross-app)
              [ "$got" = "hello from dep/greet" ] || { echo "derived-graph build mismatch: [$got]" >&2; exit 1; }
              jq -S . ${./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json} > committed.json
              jq -S . ${derived.passthru.graphFile} > derived.json
              diff -u committed.json derived.json
              echo OK > $out
            '';
          # derived build + test graphs: every per-package test runs, and both
          # graphs equal the committed ones for the same fixture.
          godyn-derived-tests-test =
            let
              derived = self.packages.${system}.godyn-derived-tests-test;
              fixture = ./pkgs/build-support/godyn/tests/gotest;
            in
            pkgs.runCommandLocal "godyn-derived-tests-test-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              res=${derived.passthru.checkAll}
              for p in example.com/gotest/leaf example.com/gotest/mid example.com/gotest; do
                grep -qx "ok $p" "$res" || { echo "missing test result for $p" >&2; cat "$res" >&2; exit 1; }
              done
              jq -S . ${fixture}/godyn-graph.json > committed.json
              jq -S . ${derived.passthru.graphFile} > derived.json
              diff -u committed.json derived.json
              jq -S . ${fixture}/godyn-test-graph.json > committed-tests.json
              jq -S . ${derived.passthru.testGraphFile} > derived-tests.json
              diff -u committed-tests.json derived-tests.json
              echo OK > $out
            '';
          # godyn must compile a module at the language version its go.mod
          # declares, like `go build`: go 1.21 closures share the loop variable.
          godyn-lang-test =
            let
              auto = self.packages.${system}.godyn-lang-test;
            in
            pkgs.runCommandLocal "godyn-lang-test-check" { } ''
              bga=$(${auto.passthru.bga}/bin/*)
              native=$(${auto.passthru.native}/bin/*)
              echo "buildGoApplication: $bga  godyn: $native"
              [ "$bga" = 333 ] || { echo "buildGoApplication did not apply go 1.21 rules: [$bga]" >&2; exit 1; }
              [ "$native" = "$bga" ] || { echo "godyn applied different language rules than go build: [$native] vs [$bga]" >&2; exit 1; }
              echo OK > $out
            '';
          godyn-cgo-test = pkgs.runCommandLocal "godyn-cgo-test-check" { } ''
            got=$(${self.packages.${system}.godyn-cgo-test}/bin/godyn-cgo-test)
            [ "$got" = 5 ] || { echo "cgo fixture printed [$got], want 5" >&2; exit 1; }
            echo OK > $out
          '';
          # The lint lane (type-bearing vetx tool) analyzes the cgo package from its
          # translated sources and hands main the cgo package's vetx; the
          # toolchain-vet lane still skips cgo packages (old protocol).
          godyn-cgo-lint-test = self.packages.${system}.godyn-cgo-test.passthru.lintAll;
          godyn-cgo-vet-test = self.packages.${system}.godyn-cgo-test.passthru.vetAll;
          # per-package lint: staticcheck's findings reach the build log and fail it;
          # a //nolint naming the golangci-lint linter suppresses the same finding.
          godyn-lint-finding-test = pkgs.testers.testBuildFailure' {
            drv = self.packages.${system}.godyn-lint-test.passthru.lint."example.com/lint/bad";
            expectedBuilderLogEntries = [ "should omit comparison to bool constant" ];
          };
          godyn-lint-nolint-test =
            self.packages.${system}.godyn-lint-test.passthru.lint."example.com/lint/ok";
          # buildGodynLint on real multi-package code (local imports, bridged dep).
          godyn-lint-clean-test = pkgs.buildGodynLint {
            pname = "godyn-cross-app";
            src = ./pkgs/build-support/godyn/tests/cross/app;
            graphFile = ./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json;
            bridges."example.com/dep" = ./pkgs/build-support/godyn/tests/cross/dep;
          };

          # gomod2nix hermetic lint lane (FDR 0006, igloo#62): buildGoLint must
          # resolve a goFlakeInputs-bridged-ONLY package inside the sandbox,
          # offline. `lint` (bridged) builds green; `control` (no bridge) MUST
          # fail its package load — asserted via testBuildFailure' so a
          # regression that lets the unbridged case pass fails this check.
          gocheck-lint = gocheck.lint;
          gocheck-control-rejects = pkgs.testers.testBuildFailure' {
            drv = gocheck.control;
            expectedBuilderLogEntries = [
              "cannot find module providing package example.com/producer/newpkg"
            ];
          };
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

      inherit (nixpkgs-master) nixosModules;
    };
}
