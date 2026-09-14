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
            go-toolchain-man
            godyn-man
            nixgc-man
            update-zx-deps
            ;
          # Every igloo man page in one share/man root (godyn(7), gomod2nix(7),
          # mkGoPkgs(7), goSourceFilter(7), go-toolchain(7), nixgc(1)), for a
          # consumer's profile or first-party manpath to install by name.
          manpages = pkgs.symlinkJoin {
            name = "igloo-manpages";
            paths = [
              pkgs.godyn-man
              pkgs.gomod2nix-man
              pkgs.go-toolchain-man
              pkgs.nixgc-man
            ];
          };
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
          inherit (pkgs)
            godyn-gen
            godyn-go
            godyn-test
            nixgc
            ;
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
              mkdir -p $out/share/man/man1 && echo '.TH GODYN-CROSS-APP 1' > $out/share/man/man1/godyn-cross-app.1
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
          # go.nix alone (FDR 0008): no go.mod in the tree; go.mod, gomod2nix.toml and
          # the package graph are rendered/derived from the manifest, and the fleet
          # module resolves as a flake input's packages.<system>.go-pkgs.
          godyn-manifest-test = pkgs.buildGodynModule {
            pname = "godyn-manifest-test";
            src = ./pkgs/build-support/godyn/tests/manifest;
            manifest = ./pkgs/build-support/godyn/tests/manifest/go.nix;
            inputs.dep.packages.${system}.go-pkgs = ./pkgs/build-support/godyn/tests/cross;
            version = "0.0.0";
            subPackages = [ "." ]; # tools/gen is a generator, not a product
            tests = true;
            goRunInputs = [ pkgs.hello ]; # a tool every escape-hatch run has on PATH
          };
          # go.nix with -race on both backends (spinclass's variant, FDR 0008).
          godyn-manifest-race-test = pkgs.buildGoAuto {
            pname = "godyn-manifest-race-test";
            src = ./pkgs/build-support/godyn/tests/manifest;
            manifest = ./pkgs/build-support/godyn/tests/manifest/go.nix;
            inputs.dep.packages.${system}.go-pkgs = ./pkgs/build-support/godyn/tests/cross;
            version = "0.0.0";
            subPackages = [ "." ];
            race = true;
            nativeArgs.cc = pkgs.stdenv.cc; # -race requires cgo
          };
          # buildGoAuto with go.nix: both backends build from the one manifest; tests
          # reaches the godyn backend, and a bgaArgs.pwd at the (go.mod-less)
          # checkout is redirected to the rendered tree (spinclass's shape).
          godyn-manifest-auto-test = pkgs.buildGoAuto {
            pname = "godyn-manifest-auto-test";
            src = ./pkgs/build-support/godyn/tests/manifest;
            manifest = ./pkgs/build-support/godyn/tests/manifest/go.nix;
            inputs.dep.packages.${system}.go-pkgs = ./pkgs/build-support/godyn/tests/cross;
            version = "0.0.0";
            subPackages = [ "." ];
            tests = true;
            bgaArgs.pwd = ./pkgs/build-support/godyn/tests/manifest;
          };
          # flake-input-go_mod producers under godyn: q and p publish go-pkgs via
          # mkGoPkgs (p's carries goFlakeInputs for q). godyn builds consumer c from
          # a derived graph declaring ONLY p — q must be inherited — and builds p
          # from its own go-pkgs-test (self-consumption, a derivation as src).
          godyn-producer-consumer-test =
            let
              q = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/q;
                name = "q";
              };
              p = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/p;
                name = "p";
                goFlakeInputs."example.com/q" = q.go-pkgs;
              };
            in
            pkgs.buildGodynModule {
              pname = "godyn-producer-consumer-test";
              src = ./pkgs/build-support/godyn/tests/producer/c;
              modules = ./pkgs/build-support/godyn/tests/producer/c/gomod2nix.toml;
              goFlakeInputs."example.com/p" = p.go-pkgs;
              version = "0.0.0";
            };
          # go.nix on BOTH sides of RFC 0001 (FDR 0008). pm is producer p described
          # by go.nix: mkGoPkgs renders go.mod/gomod2nix.toml into its go-pkgs and
          # resolves its flakeInputs (q) into passthru.goFlakeInputs. The go.nix
          # consumer cm bridges it through `inputs`; q is also a third-party require
          # in cm's manifest (bogus hash) — the inherited bridge must win and the
          # hash never be fetched.
          godyn-producer-manifest-test =
            let
              inherit (self.packages.${system}.godyn-producer-gonix-test.passthru) pm;
            in
            pkgs.buildGoAuto {
              pname = "godyn-producer-manifest-test";
              src = ./pkgs/build-support/godyn/tests/producer/cm;
              manifest = ./pkgs/build-support/godyn/tests/producer/cm/go.nix;
              inputs.p.packages.${system}.go-pkgs = pm.go-pkgs;
              version = "0.0.0";
            };
          # The ORGANIC consumer c (go.mod + gomod2nix.toml) bridging the go.nix
          # producer pm through goFlakeInputs, on both backends: a producer's cutover
          # must be invisible to consumers that have not cut over. passthru.pm is the
          # producer for the other fixtures.
          godyn-producer-gonix-test =
            let
              q = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/q;
                name = "q";
              };
              pm = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/pm;
                manifest = ./pkgs/build-support/godyn/tests/producer/pm/go.nix;
                inputs.q.packages.${system}.go-pkgs = q.go-pkgs;
              };
            in
            (pkgs.buildGoAuto {
              pname = "godyn-producer-gonix-test";
              src = ./pkgs/build-support/godyn/tests/producer/c;
              modules = ./pkgs/build-support/godyn/tests/producer/c/gomod2nix.toml;
              goFlakeInputs."example.com/p" = pm.go-pkgs;
              version = "0.0.0";
            }).overrideAttrs
              (old: {
                passthru = old.passthru // {
                  inherit pm q;
                };
              });
          # A go.nix producer whose module is a subdirectory of the published tree
          # (mkGoPkgs subPath; crap's go-crap/): the organic consumer c bridges it
          # with the same subPath on both backends.
          godyn-producer-subpath-test =
            let
              inherit (self.packages.${system}.godyn-producer-gonix-test.passthru) q;
              psub = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/sub;
                manifest = ./pkgs/build-support/godyn/tests/producer/sub/p/go.nix;
                subPath = "p";
                inputs.q.packages.${system}.go-pkgs = q.go-pkgs;
              };
            in
            (pkgs.buildGoAuto {
              pname = "godyn-producer-subpath-test";
              src = ./pkgs/build-support/godyn/tests/producer/c;
              modules = ./pkgs/build-support/godyn/tests/producer/c/gomod2nix.toml;
              goFlakeInputs."example.com/p" = {
                src = psub.go-pkgs;
                subPath = "p";
              };
              version = "0.0.0";
            }).overrideAttrs
              (old: {
                passthru = old.passthru // {
                  inherit psub;
                };
              });
          # The go.nix producer self-consuming its go-pkgs-test (the RFC 0001
          # producer contract): its rendered files drive the build and its tests run.
          godyn-producer-gonix-self-test =
            let
              inherit (self.packages.${system}.godyn-producer-gonix-test.passthru) pm q;
            in
            # src is the producer's own go-pkgs-test, which carries this manifest's
            # rendered go.mod — accepted as is, so one build serves the producer's
            # tests AND godyn-go's ingest/goRun (no second manifest attribute).
            pkgs.buildGodynModule {
              pname = "godyn-producer-gonix-self-test";
              src = pm.go-pkgs-test;
              manifest = ./pkgs/build-support/godyn/tests/producer/pm/go.nix;
              inputs.q.packages.${system}.go-pkgs = q.go-pkgs;
              version = "0.0.0";
              tests = true;
            };
          godyn-producer-self-test =
            let
              q = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/q;
                name = "q";
              };
              p = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/p;
                name = "p";
                goFlakeInputs."example.com/q" = q.go-pkgs;
              };
            in
            pkgs.buildGodynModule {
              pname = "godyn-producer-self-test";
              src = p.go-pkgs-test;
              modules = "${p.go-pkgs-test}/gomod2nix.toml";
              goFlakeInputs."example.com/q" = q.go-pkgs;
              version = "0.0.0";
              tests = true;
            };
          # build tags: the same module untagged, and tagged `test` with per-package
          # tests (a tagged helper in lib is used by user's untagged test, so lib
          # must compile under the tag) plus a testEnv the tests read.
          godyn-tags-plain = pkgs.buildGodynModule {
            pname = "godyn-tags-plain";
            src = ./pkgs/build-support/godyn/tests/buildtags;
            modules = ./pkgs/build-support/godyn/tests/buildtags/gomod2nix.toml;
            version = "0.0.0";
          };
          godyn-tags-test = pkgs.buildGodynModule {
            pname = "godyn-tags-test";
            src = ./pkgs/build-support/godyn/tests/buildtags;
            modules = ./pkgs/build-support/godyn/tests/buildtags/gomod2nix.toml;
            version = "0.0.0";
            tags = [ "test" ];
            tests = true;
            testEnv.GODYN_TEST_ENV = "set";
          };
          # test-only link flags: testLdflagsX burns a value into the package main's
          # TEST binary (full import path, as the variant is -p <importpath>).
          godyn-testldflags-test = pkgs.buildGodynModule {
            pname = "godyn-testldflags-test";
            src = ./pkgs/build-support/godyn/tests/testldflags;
            modules = ./pkgs/build-support/godyn/tests/testldflags/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
            testLdflagsX."example.com/testld.fixture" = "burned";
          };
          # go test's recompiled dependents: a's external test imports b, which
          # imports a, so b must be recompiled against a's test variant.
          godyn-fortest-test = pkgs.buildGodynModule {
            pname = "godyn-fortest-test";
            src = ./pkgs/build-support/godyn/tests/fortest;
            modules = ./pkgs/build-support/godyn/tests/fortest/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
          };
          # test-only bridged dependency: only t's test imports q (a producer's
          # go-pkgs), so q enters the build graph only via godyn-gen -test-deps.
          godyn-testonly-bridge-test =
            let
              q = pkgs.mkGoPkgs {
                src = ./pkgs/build-support/godyn/tests/producer/q;
                name = "q";
              };
            in
            pkgs.buildGodynModule {
              pname = "godyn-testonly-bridge-test";
              src = ./pkgs/build-support/godyn/tests/producer/t;
              modules = ./pkgs/build-support/godyn/tests/producer/t/gomod2nix.toml;
              goFlakeInputs."example.com/q" = q.go-pkgs;
              version = "0.0.0";
              tests = true;
            };
          # a main under testdata/ (skipped by ./...) selected via subPackages.
          godyn-testdata-main-test = pkgs.buildGodynModule {
            pname = "godyn-testdata-main-test";
            src = ./pkgs/build-support/godyn/tests/multi;
            modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
            subPackages = [ "tools/testdata/fix" ];
          };
          # a test that shells out to a tool from nativeCheckInputs.
          godyn-checkinputs-test = pkgs.buildGodynModule {
            pname = "godyn-checkinputs-test";
            src = ./pkgs/build-support/godyn/tests/checkinputs;
            modules = ./pkgs/build-support/godyn/tests/checkinputs/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
            nativeCheckInputs = [ pkgs.hello ];
          };
          # binary naming: like `go install` on both backends by default; binaryNames
          # overrides it on both, for a subdir main and for the module-root main.
          godyn-binary-name-test = pkgs.buildGoAuto {
            pname = "godyn-binary-name-test";
            src = ./pkgs/build-support/godyn/tests/multi;
            modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
            subPackages = [
              "cmd/alpha"
              "cmd/beta"
            ];
            binaryNames."cmd/beta" = "custom-beta";
            version = "0.0.0";
          };
          godyn-binary-name-root-test = pkgs.buildGoAuto {
            pname = "godyn-binary-name-root-test";
            src = ./pkgs/build-support/godyn/tests/cross/app;
            graphFile = ./pkgs/build-support/godyn/tests/cross/app/godyn-graph.json;
            goFlakeInputs = {
              "example.com/dep" = {
                src = ./pkgs/build-support/godyn/tests/cross;
                subPath = "dep";
              };
            };
            version = "0.0.0";
            binaryNames."." = "renamed-app";
          };
          # race = true: race stdlib, race-tagged graph, -race compiles/links, incl.
          # test binaries; the plain build of the same module for contrast.
          godyn-race-test = pkgs.buildGodynModule {
            pname = "godyn-race-test";
            src = ./pkgs/build-support/godyn/tests/race;
            modules = ./pkgs/build-support/godyn/tests/race/gomod2nix.toml;
            version = "0.0.0";
            race = true;
            cc = pkgs.stdenv.cc; # -race requires cgo
            tests = true;
          };
          # buildGoAuto race = true: godyn natively, bga through buildGoRace.
          godyn-race-auto-test = pkgs.buildGoAuto {
            pname = "godyn-race-auto-test";
            src = ./pkgs/build-support/godyn/tests/race;
            modules = ./pkgs/build-support/godyn/tests/race/gomod2nix.toml;
            version = "0.0.0";
            subPackages = [ "." ];
            race = true;
            nativeArgs.cc = pkgs.stdenv.cc;
          };
          godyn-race-plain-test = pkgs.buildGodynModule {
            pname = "godyn-race-plain-test";
            src = ./pkgs/build-support/godyn/tests/race;
            modules = ./pkgs/build-support/godyn/tests/race/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
          };
          # testPreRun prepares a writable HOME before the test binary; testFlags
          # filters which tests it runs.
          godyn-testhooks-test = pkgs.buildGodynModule {
            pname = "godyn-testhooks-test";
            src = ./pkgs/build-support/godyn/tests/testhooks;
            modules = ./pkgs/build-support/godyn/tests/testhooks/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
            testPreRun = ''
              export HOME="$TMPDIR/home" GODYN_PRERUN=ran
              mkdir -p "$HOME"
            '';
            testFlags = [ "-test.run=^TestWritableHome$" ];
          };
          # a test reading ../../docs/vec.txt: testFiles (the golden path) places the
          # file in the run tree; testModuleTree (discouraged) runs in the module.
          godyn-testfiles-test = pkgs.buildGodynModule {
            pname = "godyn-testfiles-test";
            src = ./pkgs/build-support/godyn/tests/testfiles;
            modules = ./pkgs/build-support/godyn/tests/testfiles/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
            testFiles."inner/p" = [ "docs/vec.txt" ];
          };
          godyn-testmoduletree-test = pkgs.buildGodynModule {
            pname = "godyn-testmoduletree-test";
            src = ./pkgs/build-support/godyn/tests/testfiles;
            modules = ./pkgs/build-support/godyn/tests/testfiles/gomod2nix.toml;
            version = "0.0.0";
            tests = true;
            testModuleTree = true;
          };
          # cgo flags cmd/go resolves before cgo runs: `#cgo pkg-config: zlib` plus a
          # -D define that only CGO_CFLAGS supplies (maneater's shape).
          godyn-cgo-pkgconfig-test = pkgs.buildGodynModule {
            pname = "godyn-cgo-pkgconfig-test";
            src = ./pkgs/build-support/godyn/tests/cgo-pkgconfig;
            modules = ./pkgs/build-support/godyn/tests/cgo-pkgconfig/gomod2nix.toml;
            cc = pkgs.stdenv.cc;
            buildInputs = [ pkgs.zlib ];
            # split like cmd/go: the unquoted field keeps its literal quotes (the
            # form buildGoApplication users write); a quoted field may hold a space.
            CGO_CFLAGS = "-DGODYN_MARK=\"flag-ok\" '-DGODYN_MARK2=\"quoted ok\"'";
            # use/'s test binary links over the cgo zv: external link with cc.
            tests = true;
          };
          # Multi-binary module: two commands over a shared package, graph derived.
          # All mains link by default; subPackages selects.
          godyn-multi-test = pkgs.buildGodynModule {
            pname = "godyn-multi-test";
            src = ./pkgs/build-support/godyn/tests/multi;
            modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
          };
          # -cover: the gotest fixture's packages instrumented (incl. an embed
          # package) with per-package test runs; and a covered binary.
          godyn-cover-test = pkgs.buildGodynModule {
            pname = "godyn-cover-test";
            src = ./pkgs/build-support/godyn/tests/gotest;
            modules = ./pkgs/build-support/godyn/tests/gotest/gomod2nix.toml;
            tests = true;
            cover = true;
          };
          godyn-cover-bin-test = pkgs.buildGodynModule {
            pname = "godyn-cover-bin-test";
            src = ./pkgs/build-support/godyn/tests/multi;
            modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
            cover = true;
          };
          # gcflags reach every compile: the same module with -N -l (no optimizing,
          # no inlining) produces different package archives.
          godyn-gcflags-test = pkgs.buildGodynModule {
            pname = "godyn-gcflags-test";
            src = ./pkgs/build-support/godyn/tests/multi;
            modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
            gcflags = [
              "-N"
              "-l"
            ];
          };
          godyn-multi-sub-test = pkgs.buildGodynModule {
            pname = "godyn-multi-sub-test";
            src = ./pkgs/build-support/godyn/tests/multi;
            modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
            subPackages = [ "cmd/beta" ];
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
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-embed-test})
            want="godyn embed works"
            [ "$got" = "$want" ] || { echo "embed mismatch: got [$got] want [$want]" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-ldflags-test = pkgs.runCommandLocal "godyn-ldflags-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-ldflags-test})
            want="version=9.9.9 commit=unknown channel=stable"
            [ "$got" = "$want" ] || { echo "ldflags mismatch: got [$got] want [$want]" >&2; exit 1; }
            echo OK > $out
          '';
          # igloo#68: every pattern embeds its files — the templates glob (not
          # ignore.txt) and the static tree minus its dot-file.
          godyn-embed-glob-test = pkgs.runCommandLocal "godyn-embed-glob-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-embed-glob-test})
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
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-selector-test})
            [ "$got" = "godyn embed works" ] || { echo "selector native mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          # per-system graph selection (graphFiles, igloo#33): the graph resolved via
          # graphFiles.''${system} builds a working binary.
          godyn-graphfiles-test = pkgs.runCommandLocal "godyn-graphfiles-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-graphfiles-test})
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
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-cross-source})
            [ "$got" = "hello from dep/greet" ] || { echo "bridges (source) mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-cross-archive = pkgs.runCommandLocal "godyn-cross-archive-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-cross-archive})
            [ "$got" = "hello from dep/greet" ] || { echo "archiveBridges (output) mismatch: [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-auto-goflakeinputs-test = pkgs.runCommandLocal "godyn-auto-goflakeinputs-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-auto-goflakeinputs-test})
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
                [ -e "$pkg/share/man/man1/godyn-cross-app.1.gz" ] || { echo "$pkg: stdenv fixup did not compress the man page" >&2; ls -R "$pkg/share" >&2; exit 1; }
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
              got=$(${pkgs.lib.getExe derived})
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
          # go.nix: the manifest-only build runs; the third-party module compiles at
          # its own go directive (1.13, as the manifest records); the tree tracks no
          # go.mod; and go.mod -> manifest -> go.mod is lossless for every field the
          # manifest owns (fleet pairs, indirect markers, path/module/versioned replaces).
          godyn-manifest-test =
            let
              built = self.packages.${system}.godyn-manifest-test;
              auto = self.packages.${system}.godyn-manifest-auto-test;
              manifestLib = pkgs.callPackage ./pkgs/build-support/godyn/manifest.nix { };
              fixture = ./pkgs/build-support/godyn/tests/manifest;
              roundTrip = builtins.readFile ./pkgs/build-support/godyn/tests/manifest/roundtrip.gomod;
              rendered = manifestLib.renderGoMod {
                manifest = manifestLib.fromGoMod {
                  text = roundTrip;
                  hashes = {
                    "github.com/google/go-cmp" = "sha256-go-cmp";
                    "golang.org/x/text" = "sha256-text";
                  };
                  flakeInputs."example.com/dep".input = "dep";
                };
                flakeInputTargets."example.com/dep" = "/fleet/dep";
              };
            in
            assert !builtins.pathExists "${fixture}/go.mod";
            pkgs.runCommandLocal "godyn-manifest-test-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              got=$(${pkgs.lib.getExe built})
              [ "$got" = "hello from dep/greet true" ] || { echo "manifest build printed [$got]" >&2; exit 1; }
              for b in ${auto.passthru.native}/bin/manifest ${auto.passthru.bga}/bin/manifest; do
                got=$("$b")
                [ "$got" = "hello from dep/greet true" ] || { echo "$b printed [$got]" >&2; exit 1; }
              done
              grep -qx "ok example.com/manifest" ${auto.passthru.checkAll} || { echo "buildGoAuto tests = true: no test run" >&2; exit 1; }
              lang=$(jq -r '.[] | select(.importPath == "github.com/google/go-cmp/cmp") | .goVersion' ${built.passthru.graphFile})
              [ "$lang" = "1.13" ] || { echo "go-cmp goVersion in the derived graph: [$lang], want 1.13" >&2; exit 1; }
              grep -q 'goVersion = "1.13"' ${
                builtins.toFile "rendered.toml" (manifestLib.renderGomod2nixToml (fixture + "/go.nix"))
              } \
                || { echo "rendered gomod2nix.toml lost go-cmp's goVersion" >&2; exit 1; }
              diff -u ${builtins.toFile "roundtrip.gomod" roundTrip} ${builtins.toFile "rendered.gomod" rendered}
              echo OK > $out
            '';
          # go.nix tracer bullet (FDR 0008): the manifest module's per-package test,
          # vet and lint lanes run from the derived graphs, and its -race variant
          # builds on both backends.
          godyn-manifest-tests-test =
            let
              built = self.packages.${system}.godyn-manifest-test;
              race = self.packages.${system}.godyn-manifest-race-test;
            in
            pkgs.runCommandLocal "godyn-manifest-tests-test-check" { } ''
              grep -qx "ok example.com/manifest" ${built.passthru.checkAll} || {
                echo "missing test result for example.com/manifest" >&2; cat ${built.passthru.checkAll} >&2; exit 1; }
              for b in ${race.passthru.native}/bin/manifest ${race.passthru.bga}/bin/manifest; do
                got=$("$b")
                [ "$got" = "hello from dep/greet true" ] || { echo "$b printed [$got]" >&2; exit 1; }
              done
              echo OK > $out
            '';
          godyn-manifest-vet-test = self.packages.${system}.godyn-manifest-test.passthru.vetAll;
          godyn-manifest-lint-test = self.packages.${system}.godyn-manifest-test.passthru.lintAll;
          # pure codegen drift check (FDR 0008): go generate runs the fixture's
          # generator in the vendored module tree; the committed generated.go matches
          # (green), and a command that changes the tree fails naming the drift —
          # through buildGoAuto's passthru, which spinclass wires.
          godyn-manifest-codegen-test =
            self.packages.${system}.godyn-manifest-auto-test.passthru.codegenCheck
              {
                command = "go generate ./...";
              };
          # ingest (FDR 0008), the pure half of the escape hatch: from a goRun
          # output captured after `go get github.com/google/go-cmp@v0.7.0` (its
          # go.mod carries the fleet module's sentinel require and store-path
          # replace), the manifest gains the bumped version, hash and Go version,
          # keeps its flakeInputs, records no bridge — and the rendered go.nix
          # evaluates back to the same data.
          godyn-manifest-ingest-test =
            let
              m = pkgs.callPackage ./pkgs/build-support/godyn/manifest.nix { };
              fixture = ./pkgs/build-support/godyn/tests/manifest;
              ingested = m.ingest {
                manifest = fixture + "/go.nix";
                out = fixture + "/escape-hatch";
              };
              expected = (m.load (fixture + "/go.nix")) // {
                require."github.com/google/go-cmp" = {
                  version = "v0.7.0";
                  hash = "sha256-JbxZFBFGCh/Rj5XZ1vG94V2x7c18L8XKB0N9ZD5F2rM=";
                  go = "1.21";
                };
              };
              rendered = m.renderGoNix ingested;
              viaCli = self.packages.${system}.godyn-manifest-test.passthru.ingest (fixture + "/escape-hatch");
            in
            assert m.load ingested == expected;
            assert m.load (import (builtins.toFile "go.nix" rendered)) == expected;
            assert viaCli == rendered;
            # expected.go.nix is committed and therefore formatted by the repo's
            # nix formatter: a byte-equal render proves ingest's output is
            # nixfmt-stable, so consumers need not exclude go.nix from formatting.
            pkgs.runCommandLocal "godyn-manifest-ingest-test-check" { } ''
              diff -u ${fixture + "/escape-hatch/expected.go.nix"} ${builtins.toFile "ingested.go.nix" rendered}
              echo OK > $out
            '';
          # migration (FDR 0008): ingest over a checkout's own go.mod + gomod2nix.toml
          # — seeded with module, go and the fleet modules as flakeInputs — yields a
          # manifest whose rendered go.mod parses equal to the original minus the
          # fleet module's require and relative-path replace (cross/app), and, for a
          # module with third-party requires (the gomod2nix CLI: two require blocks,
          # indirect markers), carries the toml's hashes.
          godyn-manifest-migrate-test =
            let
              m = pkgs.callPackage ./pkgs/build-support/godyn/manifest.nix { };
              inherit (import ./pkgs/build-support/gomod2nix/parser.nix) parseGoMod;
              app = ./pkgs/build-support/godyn/tests/cross/app;
              lang = ./pkgs/build-support/gomod2nix/cli;
              appManifest = m.ingest {
                manifest = {
                  inherit (parseGoMod (builtins.readFile (app + "/go.mod"))) module go;
                  flakeInputs."example.com/dep".input = "dep";
                };
                out = app;
              };
              langGoMod = parseGoMod (builtins.readFile (lang + "/go.mod"));
              langManifest = m.ingest {
                manifest = { inherit (langGoMod) module go; };
                out = lang;
              };
              langToml = builtins.fromTOML (builtins.readFile (lang + "/gomod2nix.toml"));
            in
            assert appManifest.require == { };
            assert appManifest.replace == { };
            assert appManifest.flakeInputs."example.com/dep".input == "dep";
            assert parseGoMod (m.renderGoMod { manifest = langManifest; }) == langGoMod;
            assert
              pkgs.lib.mapAttrs (_: r: r.hash) langManifest.require
              == pkgs.lib.mapAttrs (_: v: v.hash) langToml.mod;
            pkgs.runCommandLocal "godyn-manifest-migrate-test-check" { } "echo OK > $out";
          godyn-manifest-codegen-drift-test = pkgs.testers.testBuildFailure' {
            drv = self.packages.${system}.godyn-manifest-test.passthru.codegenCheck {
              command = "go generate ./... && echo '// drift' >> generated.go";
            };
            expectedBuilderLogEntries = [ "godyn codegen drift (godyn-manifest-test)" ];
          };
          # inner test loop (FDR 0008): testWith runs one package's tests with extra
          # flags and keeps the output — here verbose, filtered to leaf's tests.
          godyn-test-with-test =
            let
              run = self.packages.${system}.godyn-derived-tests-test.passthru.testWith {
                dir = "./leaf";
                testFlags = [
                  "-test.run=."
                  "-test.v"
                ];
              };
            in
            pkgs.runCommandLocal "godyn-test-with-test-check" { } ''
              grep -qx "ok example.com/gotest/leaf" ${run}/result || { echo "result: $(cat ${run}/result)" >&2; exit 1; }
              grep -q '^=== RUN' ${run}/test.log || { echo "no verbose output in test.log:" >&2; cat ${run}/test.log >&2; exit 1; }
              echo OK > $out
            '';
          # producers: the consumer links p and the INHERITED q; p's own tests pass
          # when godyn builds it from its published go-pkgs-test.
          godyn-producer-test = pkgs.runCommandLocal "godyn-producer-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-producer-consumer-test})
            [ "$got" = "p wraps q" ] || { echo "consumer printed [$got]" >&2; exit 1; }
            grep -qx "ok example.com/p" ${self.packages.${system}.godyn-producer-self-test.passthru.checkAll} \
              || { echo "p's tests did not run from go-pkgs-test" >&2; exit 1; }
            echo OK > $out
          '';
          # go.nix consumer with q both required (bogus hash) and inherited-bridged:
          # both backends build and run, the graph sources q from the bridge, and
          # the vendor tree carries no q — the bridge shadows the require.
          godyn-producer-manifest-test =
            let
              m = self.packages.${system}.godyn-producer-manifest-test;
            in
            pkgs.runCommandLocal "godyn-producer-manifest-test-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              for b in ${m.passthru.native}/bin/c ${m.passthru.bga}/bin/c; do
                got=$("$b")
                [ "$got" = "p wraps q" ] || { echo "$b printed [$got]" >&2; exit 1; }
              done
              dir=$(jq -r '.[] | select(.importPath == "example.com/q") | .dir' ${m.passthru.native.passthru.graphFile})
              case "$dir" in
                */vendor/*) echo "q sourced from the vendor tree: $dir" >&2; exit 1 ;;
              esac
              [ ! -e ${m.passthru.native.passthru.vendorEnv}/example.com/q ] || { echo "vendor tree carries q" >&2; exit 1; }
              echo OK > $out
            '';
          # go.nix producer (FDR 0008): its go-pkgs carry a rendered go.mod (module,
          # go, a sentinel require for q, no replace) and gomod2nix.toml, and
          # passthru.goFlakeInputs names q; the organic consumer c builds and runs
          # against it on both backends; the producer's own tests pass from its
          # go-pkgs-test.
          godyn-producer-gonix-test =
            let
              t = self.packages.${system}.godyn-producer-gonix-test;
              inherit (t.passthru) pm;
              selfTest = self.packages.${system}.godyn-producer-gonix-self-test;
            in
            assert pm.go-pkgs.passthru.goFlakeInputs ? "example.com/q";
            pkgs.runCommandLocal "godyn-producer-gonix-test-check" { } ''
              grep -qx "module example.com/p" ${pm.go-pkgs}/go.mod
              grep -q "example.com/q v0.0.0-00010101000000-000000000000" ${pm.go-pkgs}/go.mod
              ! grep -q "replace" ${pm.go-pkgs}/go.mod
              grep -qx "schema = 3" ${pm.go-pkgs}/gomod2nix.toml
              [ -f ${pm.go-pkgs}/go.nix ] && [ -f ${pm.go-pkgs-test}/go.mod ] && [ -f ${pm.go-pkgs-test}/p_test.go ]
              [ ! -f ${pm.go-pkgs}/p_test.go ]
              for b in ${t.passthru.native}/bin/c ${t.passthru.bga}/bin/c; do
                got=$("$b")
                [ "$got" = "p wraps q" ] || { echo "$b printed [$got]" >&2; exit 1; }
              done
              grep -qx "ok example.com/p" ${selfTest.passthru.checkAll} || { echo "p's tests did not run" >&2; exit 1; }
              echo OK > $out
            '';
          # subPath producer: the render sits at go-pkgs/p/, not the root, and the
          # consumer bridging with subPath "p" builds and runs on both backends.
          godyn-producer-subpath-test =
            let
              t = self.packages.${system}.godyn-producer-subpath-test;
              inherit (t.passthru) psub;
            in
            assert psub.go-pkgs.name == "p-go-pkgs";
            pkgs.runCommandLocal "godyn-producer-subpath-test-check" { } ''
              [ -f ${psub.go-pkgs}/p/go.mod ] && [ -f ${psub.go-pkgs}/p/gomod2nix.toml ] && [ ! -e ${psub.go-pkgs}/go.mod ]
              grep -qx "module example.com/p" ${psub.go-pkgs}/p/go.mod
              for b in ${t.passthru.native}/bin/c ${t.passthru.bga}/bin/c; do
                got=$("$b")
                [ "$got" = "p wraps q" ] || { echo "$b printed [$got]" >&2; exit 1; }
              done
              echo OK > $out
            '';
          # build tags select files in the derived graph: untagged links the
          # default file, tagged the other; the tagged tests (cross-package tagged
          # helper, testEnv) all pass.
          godyn-tags-test =
            let
              plain = self.packages.${system}.godyn-tags-plain;
              tagged = self.packages.${system}.godyn-tags-test;
            in
            pkgs.runCommandLocal "godyn-tags-test-check" { } ''
              [ "$(${pkgs.lib.getExe plain})" = default ] || { echo "untagged build did not select mode_default.go" >&2; exit 1; }
              [ "$(${pkgs.lib.getExe tagged})" = tagged ] || { echo "tagged build did not select mode_tagged.go" >&2; exit 1; }
              for p in example.com/tags/lib example.com/tags/user; do
                grep -qx "ok $p" ${tagged.passthru.checkAll} || { echo "missing tagged test result for $p" >&2; exit 1; }
              done
              echo OK > $out
            '';
          # testLdflagsX reaches the test binary (its test passes) but not the release
          # binary (still prints the default).
          godyn-testldflags-test =
            let
              drv = self.packages.${system}.godyn-testldflags-test;
            in
            pkgs.runCommandLocal "godyn-testldflags-test-check" { } ''
              [ "$(${pkgs.lib.getExe drv})" = unset ] || { echo "testLdflagsX leaked into the release link" >&2; exit 1; }
              grep -qx "ok example.com/testld" ${drv.passthru.checkAll} || { echo "test binary did not get the -X value" >&2; exit 1; }
              echo OK > $out
            '';
          # recompiled dependents: the derived test graph records b as recompiled
          # for a's test, and a's tests link and pass (no fingerprint mismatch).
          godyn-fortest-test =
            let
              drv = self.packages.${system}.godyn-fortest-test;
            in
            pkgs.runCommandLocal "godyn-fortest-test-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              rc=$(jq -c '.[] | select(.importPath == "example.com/fortest/a") | .recompiled' ${drv.passthru.testGraphFile})
              [ "$rc" = '["example.com/fortest/b"]' ] || { echo "recompiled for a: [$rc]" >&2; exit 1; }
              grep -qx "ok example.com/fortest/a" ${drv.passthru.checkAll} || { echo "a's tests did not pass" >&2; exit 1; }
              echo OK > $out
            '';
          # a package only a test imports (from a bridged producer) is in the build
          # graph, so t's test links and passes.
          godyn-testonly-bridge-test = pkgs.runCommandLocal "godyn-testonly-bridge-test-check" { } ''
            grep -qx "ok example.com/t" ${
              self.packages.${system}.godyn-testonly-bridge-test.passthru.checkAll
            } \
              || { echo "t's test (test-only bridged dep) did not pass" >&2; exit 1; }
            echo OK > $out
          '';
          # subPackages reaches a main under testdata/, like buildGoApplication.
          godyn-testdata-main-test = pkgs.runCommandLocal "godyn-testdata-main-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-testdata-main-test})
            [ "$got" = "hello from testdata fixture" ] || { echo "testdata main printed [$got]" >&2; exit 1; }
            echo OK > $out
          '';
          # nativeCheckInputs are on PATH in the per-package test run.
          godyn-checkinputs-test = pkgs.runCommandLocal "godyn-checkinputs-test-check" { } ''
            grep -qx "ok example.com/ci" ${self.packages.${system}.godyn-checkinputs-test.passthru.checkAll} \
              || { echo "the test could not run a nativeCheckInputs tool" >&2; exit 1; }
            echo OK > $out
          '';
          # buildGoAuto's default strategy follows godynSystems: godyn where it is
          # validated, buildGoApplication elsewhere (no per-consumer system checks).
          godyn-auto-default-strategy-test =
            let
              backend =
                (pkgs.buildGoAuto {
                  pname = "godyn-multi-auto";
                  src = ./pkgs/build-support/godyn/tests/multi;
                  modules = ./pkgs/build-support/godyn/tests/multi/gomod2nix.toml;
                  subPackages = [ "cmd/alpha" ];
                  version = "0.0.0";
                }).passthru.backend;
              want = if builtins.elem system pkgs.godynSystems then "native" else "bga";
            in
            assert backend == want;
            pkgs.runCommandLocal "godyn-auto-default-strategy-test-check" { } ''
              echo ${backend} > $out
            '';
          # -cover: tests pass instrumented, their counters merge into coverage.out
          # with per-package percentages; a covered binary writes coverage metadata
          # under GOCOVERDIR.
          godyn-cover-test =
            let
              cov = self.packages.${system}.godyn-cover-test;
              bin = self.packages.${system}.godyn-cover-bin-test;
            in
            pkgs.runCommandLocal "godyn-cover-test-check" { } ''
              for p in example.com/gotest/leaf example.com/gotest/mid example.com/gotest; do
                grep -qx "ok $p" ${cov.passthru.checkAll} || { echo "covered test run failed for $p" >&2; exit 1; }
              done
              grep -q '^mode: set' ${cov.passthru.coverage}/coverage.out || { echo "coverage.out has no mode line" >&2; exit 1; }
              grep -q 'example.com/gotest/leaf/leaf.go:' ${cov.passthru.coverage}/coverage.out \
                || { echo "leaf.go missing from coverage.out" >&2; cat ${cov.passthru.coverage}/coverage.out >&2; exit 1; }
              grep -q 'example.com/gotest/leaf' ${cov.passthru.coverage}/percent.txt \
                || { echo "leaf missing from percent.txt" >&2; cat ${cov.passthru.coverage}/percent.txt >&2; exit 1; }
              mkdir cd
              GOCOVERDIR=$PWD/cd ${bin}/bin/alpha > /dev/null
              ls cd | grep -q '^covmeta\.' || { echo "covered binary wrote no coverage metadata" >&2; ls -la cd >&2; exit 1; }
              echo OK > $out
            '';
          # gcflags change what gets compiled (archives differ), and the flagged build
          # still runs.
          godyn-gcflags-test =
            let
              plain = self.packages.${system}.godyn-multi-test;
              flagged = self.packages.${system}.godyn-gcflags-test;
            in
            pkgs.runCommandLocal "godyn-gcflags-test-check" { } ''
              a=${plain.passthru.archiveGoPkgs}/example.com/multi/greet/pkg.a
              b=${flagged.passthru.archiveGoPkgs}/example.com/multi/greet/pkg.a
              if cmp -s "$a" "$b"; then echo "gcflags did not change the compiled archive" >&2; exit 1; fi
              [ "$(${flagged}/bin/alpha)" = "hello from alpha" ] || { echo "gcflags build broke the binary" >&2; exit 1; }
              echo OK > $out
            '';
          # godyn and bga name binaries alike: `go install` names by default (a single
          # main too), binaryNames overrides on both backends.
          godyn-binary-name-test =
            let
              sub = self.packages.${system}.godyn-binary-name-test;
              root = self.packages.${system}.godyn-binary-name-root-test;
            in
            pkgs.runCommandLocal "godyn-binary-name-test-check" { } ''
              for pkg in ${sub.passthru.native} ${sub.passthru.bga}; do
                [ "$(ls $pkg/bin | sort | tr '\n' ' ')" = "alpha custom-beta " ] || { echo "$pkg/bin: $(ls $pkg/bin)" >&2; exit 1; }
              done
              for pkg in ${root.passthru.native} ${root.passthru.bga}; do
                [ "$(ls $pkg/bin)" = renamed-app ] || { echo "$pkg/bin: $(ls $pkg/bin)" >&2; exit 1; }
              done
              [ "$(ls ${self.packages.${system}.godyn-multi-sub-test}/bin)" = beta ] \
                || { echo "a single main is not named like go install" >&2; exit 1; }
              echo OK > $out
            '';
          # race builds select the race-tagged file and link; the plain module's test
          # passes; the race test binary reports the deliberate data race.
          godyn-race-test = pkgs.runCommandLocal "godyn-race-test-check" { } ''
            [ "$(${pkgs.lib.getExe self.packages.${system}.godyn-race-test})" = race ] \
              || { echo "race build did not select mode_race.go" >&2; exit 1; }
            [ "$(${pkgs.lib.getExe self.packages.${system}.godyn-race-plain-test})" = norace ] \
              || { echo "plain build selected the race file" >&2; exit 1; }
            grep -qx "ok example.com/racefix/racy" ${
              self.packages.${system}.godyn-race-plain-test.passthru.checkAll
            } \
              || { echo "the racy test should pass without -race" >&2; exit 1; }
            echo OK > $out
          '';
          # buildGoAuto forwards race: the godyn result is a race build, and the bga
          # escape hatch is the buildGoRace variant (evaluated, not built — the
          # fixture's racy test would fail its `go test -race` checkPhase by design).
          godyn-race-auto-test =
            let
              auto = self.packages.${system}.godyn-race-auto-test;
            in
            assert auto.passthru.native.passthru.race;
            assert pkgs.lib.hasSuffix "-race" auto.passthru.bga.pname;
            pkgs.runCommandLocal "godyn-race-auto-test-check" { } ''
              [ "$(${pkgs.lib.getExe auto.passthru.native})" = race ] \
                || { echo "buildGoAuto race did not produce a race build" >&2; exit 1; }
              echo OK > $out
            '';
          godyn-race-detects-test = pkgs.testers.testBuildFailure' {
            drv = self.packages.${system}.godyn-race-test.passthru.tests."example.com/racefix/racy";
            expectedBuilderLogEntries = [ "WARNING: DATA RACE" ];
          };
          # testPreRun runs before the binary (writable HOME, env) and testFlags reach
          # it (an always-failing test is filtered out); passthru.vendorEnv exists.
          godyn-testhooks-test =
            let
              drv = self.packages.${system}.godyn-testhooks-test;
            in
            assert drv.passthru ? vendorEnv;
            pkgs.runCommandLocal "godyn-testhooks-test-check" { } ''
              grep -qx "ok example.com/hooks" ${drv.passthru.checkAll} \
                || { echo "testPreRun/testFlags run did not pass" >&2; exit 1; }
              echo OK > $out
            '';
          # a test reading a module file outside its package passes via testFiles and
          # via testModuleTree.
          godyn-testfiles-test = pkgs.runCommandLocal "godyn-testfiles-test-check" { } ''
            for m in ${self.packages.${system}.godyn-testfiles-test.passthru.checkAll} \
                     ${self.packages.${system}.godyn-testmoduletree-test.passthru.checkAll}; do
              grep -qx "ok example.com/tf/inner/p" "$m" || { echo "$m: the out-of-package read failed" >&2; exit 1; }
            done
            echo OK > $out
          '';
          # cgo flags: the zlib headers/lib arrive via `#cgo pkg-config`, the define
          # via CGO_CFLAGS, and the binary links and runs; the lint lane analyzes it.
          godyn-cgo-pkgconfig-test = pkgs.runCommandLocal "godyn-cgo-pkgconfig-test-check" { } ''
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-cgo-pkgconfig-test})
            [ "$got" = "flag-ok quoted ok true" ] || { echo "cgo flags fixture printed [$got]" >&2; exit 1; }
            grep -qx "ok example.com/cgopc/use" ${
              self.packages.${system}.godyn-cgo-pkgconfig-test.passthru.checkAll
            } \
              || { echo "use's test (links over cgo zv) did not pass" >&2; exit 1; }
            echo OK > $out
          '';
          godyn-cgo-pkgconfig-lint-test = self.packages.${system}.godyn-cgo-pkgconfig-test.passthru.lintAll;
          # multi-binary: every main links (named like `go install`); subPackages
          # links only the selected one (named pname).
          # Every binary gets its own reproducible build ID (the GNU note the linker
          # derives from the Go one), and ships without DWARF (-w, bga's strip -S).
          godyn-multi-test =
            pkgs.runCommandLocal "godyn-multi-test-check" { nativeBuildInputs = [ pkgs.binutils ]; }
              ''
                    all=${self.packages.${system}.godyn-multi-test}
                    [ "$($all/bin/alpha)" = "hello from alpha" ] || { echo "alpha missing or wrong" >&2; ls -l $all/bin >&2; exit 1; }
                    [ "$($all/bin/beta)" = "hello from beta" ] || { echo "beta missing or wrong" >&2; ls -l $all/bin >&2; exit 1; }
                    ida=$(readelf -n $all/bin/alpha | sed -n 's/.*Build ID: //p')
                    idb=$(readelf -n $all/bin/beta | sed -n 's/.*Build ID: //p')
                    [ -n "$ida" ] && [ "$ida" != "$idb" ] || { echo "GNU build IDs not distinct: alpha=[$ida] beta=[$idb]" >&2; exit 1; }
                    if readelf -S --wide $all/bin/alpha | grep -q 'debug_info'; then echo "alpha still carries DWARF" >&2; exit 1; fi
                # the result is bin/ only (no pkg.a leaking into a symlinkJoin), for both
                # the multi-binary and the single-binary (subPackages) shapes.
                for r in $all ${self.packages.${system}.godyn-multi-sub-test}; do
                  [ "$(ls -A $r)" = bin ] || { echo "$r holds more than bin/: $(ls -A $r)" >&2; exit 1; }
                done
                    sub=${self.packages.${system}.godyn-multi-sub-test}
                    [ "$(ls $sub/bin)" = "beta" ] || { echo "subPackages linked: $(ls $sub/bin)" >&2; exit 1; }
                    [ "$($sub/bin/beta)" = "hello from beta" ] || { echo "subPackages picked the wrong main" >&2; exit 1; }
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
            got=$(${pkgs.lib.getExe self.packages.${system}.godyn-cgo-test})
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
