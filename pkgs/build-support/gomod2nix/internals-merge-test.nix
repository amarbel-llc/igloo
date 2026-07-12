# Regression tests for `mergeGomod2nixTomls` and `inheritedGoFlakeInputs`
# (gomod2nix internals).
# Build with: nix-build pkgs/build-support/gomod2nix/internals-merge-test.nix
#
# Covers:
#   - amarbel-llc/nixpkgs#50 — bridged keys MUST be stripped from the
#     merged gomod2nix.toml's `mod` table so mkVendorEnv's symlink.go
#     doesn't pre-create vendor/<X> and collide with synthetic
#     localReplaceCommands.
#   - amarbel-llc/nixpkgs#36 — depth-1 inheritance of
#     `passthru.goFlakeInputs` from each direct producer, with
#     consumer-declared entries winning on conflict.
#   - amarbel-llc/igloo#38 — the synthetic require sentinel's major is
#     derived per-module from a /vN suffix so `go mod edit -require`
#     accepts /v2+ goFlakeInputs module paths.
{ pkgs ? import ../../.. { } }:
let
  inherit (pkgs.callPackage ./internals.nix { })
    mergeGomod2nixTomls
    goFlakeInputsCoverageGaps
    mkMergedGoMod
    mkMergedView
    sentinelFor
    ;

  inherit (import ./parser.nix) parseGoMod;

  v0Sentinel = "v0.0.0-00010101000000-000000000000";

  # Fixture: consumer has its own pin for `shared` AND `only-in-consumer`.
  # Producer flake-input has pins for `shared` (different version,
  # leaks-transitively case) and `only-in-flake`.
  # Consumer bridges `shared` via goFlakeInputs.
  consumer = {
    schema = 3;
    mod = {
      "github.com/example/shared" = {
        version = "v1.0.0";
        hash = "consumer-hash";
      };
      "github.com/example/only-in-consumer" = {
        version = "v2.0.0";
        hash = "c";
      };
    };
  };

  flakeInputs = [
    {
      schema = 3;
      mod = {
        # Producer-side transitive pin for the same module the consumer
        # is bridging — this is the #50 leak vector.
        "github.com/example/shared" = {
          version = "v0.9.0";
          hash = "flake-hash";
        };
        "github.com/example/only-in-flake" = {
          version = "v3.0.0";
          hash = "f";
        };
      };
    }
  ];

  # Call mergeGomod2nixTomls with `bridgedKeys` declaring that
  # `shared` is handled by goFlakeInputs.
  merged = mergeGomod2nixTomls {
    inherit consumer flakeInputs;
    bridgedKeys = [ "github.com/example/shared" ];
  };

  # Call WITHOUT bridgedKeys to verify the legacy behaviour (used by
  # the no-goFlakeInputs path).
  mergedNoBridge = mergeGomod2nixTomls {
    inherit consumer flakeInputs;
  };

  # passthru.goFlakeInputs inheritance/resolution (formerly the depth-1 #36
  # cases here) now lives in transitive-inheritance-test.nix, which exercises
  # the depth-N resolveGoFlakeInputs + conflict-guardrail (igloo#58).

  # #38 integration fixtures. `go mod edit -replace` does not require the
  # target to exist on disk, so dummy store paths suffice for asserting
  # the require/replace formatting that mkMergedGoMod emits.
  consumerGoModFixture = pkgs.writeText "consumer-go.mod" ''
    module example.com/consumer

    go 1.26
  '';
  dummyV2Src = pkgs.runCommand "dummy-v2-src" { } "mkdir -p $out/go-crap";
  dummyV0Src = pkgs.runCommand "dummy-v0-src" { } "mkdir -p $out";

  # Building this derivation runs the real `go mod edit` pipeline: a /v2
  # module routed through goFlakeInputs MUST get a v2-major sentinel so
  # `go mod edit -require` accepts it (else the build fails here, which
  # is the #38 regression signal); a non-suffixed module keeps the v0
  # sentinel.
  mergedV2GoMod = mkMergedGoMod {
    consumerGoMod = consumerGoModFixture;
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    goFlakeInputs = {
      "github.com/amarbel-llc/crap/go-crap/v2" = {
        src = dummyV2Src;
        subPath = "go-crap";
      };
      "github.com/amarbel-llc/tap/go" = dummyV0Src;
    };
  };

  # #39 conditional-require: when the consumer ALREADY requires a bridged
  # module, mkMergedGoMod keeps the real version and emits NO sentinel — the
  # sentinel-elimination for the normal (organic-require) consumer case.
  consumerWithRequire = pkgs.writeText "consumer-organic-go.mod" ''
    module example.com/consumer

    go 1.26

    require github.com/amarbel-llc/crap/go-crap/v2 v2.1.0
  '';
  mergedOrganicGoMod = mkMergedGoMod {
    consumerGoMod = consumerWithRequire;
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    goFlakeInputs = {
      "github.com/amarbel-llc/crap/go-crap/v2" = {
        src = dummyV2Src;
        subPath = "go-crap";
      };
    };
    consumerRequires = [ "github.com/amarbel-llc/crap/go-crap/v2" ];
  };

  # #45 coverage-gap fixtures. A bridged producer whose go.mod requires
  # four modules with distinct coverage outcomes:
  #   - covered-dep: present in the effective map        → no warning
  #   - pinned-dep:  pinned in the merged gomod2nix.toml → no warning
  #   - private-dep: same org prefix, uncovered          → THE gap
  #   - public-dep:  foreign org prefix                  → out of scope
  coverageProducer = pkgs.runCommand "coverage-producer" { } ''
    mkdir -p $out/go
    cat > $out/go/go.mod <<'EOF'
    module github.com/amarbel-llc/prod/go

    go 1.26

    require (
    	github.com/amarbel-llc/covered-dep v0.1.0
    	github.com/amarbel-llc/pinned-dep v0.2.0
    	github.com/amarbel-llc/private-dep v0.3.0
    	github.com/other/public-dep v1.0.0
    )
    EOF
  '';

  coverageEffective = {
    # Record form with subPath — the go.mod lives at go/ inside the tree.
    "github.com/amarbel-llc/prod/go" = {
      src = coverageProducer;
      subPath = "go";
    };
    # Fake but syntactically valid store path (pathExists rejects
    # malformed /nix/store names outright); never realized.
    "github.com/amarbel-llc/covered-dep" =
      "/nix/store/ffffffffffffffffffffffffffffffff-covered";
  };

  coverageGaps = goFlakeInputsCoverageGaps {
    effectiveGoFlakeInputs = coverageEffective;
    inherit parseGoMod;
    pinnedModules = [ "github.com/amarbel-llc/pinned-dep" ];
  };

  # A producer tree without a go.mod (pre-modules dep, or a fake path
  # that never existed) MUST contribute nothing and MUST NOT throw.
  coverageGapsNoGoMod = goFlakeInputsCoverageGaps {
    effectiveGoFlakeInputs = {
      "github.com/amarbel-llc/tap/go" = dummyV0Src;
      "github.com/amarbel-llc/ghost" =
        "/nix/store/ffffffffffffffffffffffffffffffff-does-not-exist";
    };
    inherit parseGoMod;
  };

  # Wiring: mkMergedView exposes coverageGaps computed from the
  # effective (inherited // declared) map against the merged mod table.
  coverageConsumer = pkgs.runCommand "coverage-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26

    require github.com/amarbel-llc/prod/go v0.1.0
    EOF
  '';
  coverageMergedView = mkMergedView {
    pwd = coverageConsumer;
    modules = null;
    goFlakeInputs = coverageEffective;
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    inherit parseGoMod;
  };

  # #49 workspace-root toml fallback fixtures. A go.work-style producer
  # keeps ONE lockfile at the repo root (pinning the bridged module's
  # private dep); the bridged module lives at a subPath with no toml of
  # its own. The union must fall back to the root lockfile so the
  # producer's pins reach subPath consumers (live case: purse-first's
  # tommy pin never reaching dewey bridgers).
  workspaceProducer = pkgs.runCommand "workspace-producer" { } ''
    mkdir -p $out/libs/dewey
    cat > $out/gomod2nix.toml <<'EOF'
    schema = 3

    [mod]
      [mod.'github.com/amarbel-llc/tommy']
        version = 'v0.0.0-20260405143331-87255e87bf37'
        hash = 'sha256-0000000000000000000000000000000000000000000='
    EOF
    cat > $out/libs/dewey/go.mod <<'EOF'
    module github.com/amarbel-llc/purse-first/libs/dewey

    go 1.26

    require github.com/amarbel-llc/tommy v0.0.0-20260405143331-87255e87bf37
    EOF
  '';

  workspaceConsumer = pkgs.runCommand "workspace-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/ws-consumer

    go 1.26

    require github.com/amarbel-llc/purse-first/libs/dewey v0.3.2
    EOF
  '';

  workspaceMergedView = mkMergedView {
    pwd = workspaceConsumer;
    modules = null;
    goFlakeInputs = {
      "github.com/amarbel-llc/purse-first/libs/dewey" = {
        src = workspaceProducer;
        subPath = "libs/dewey";
      };
    };
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    inherit parseGoMod;
  };

  # Precedence: a subPath slice that HAS its own toml must win over the
  # workspace root's (the module's own lockfile is authoritative).
  bothTomlsProducer = pkgs.runCommand "both-tomls-producer" { } ''
    mkdir -p $out/go
    cat > $out/gomod2nix.toml <<'EOF'
    schema = 3

    [mod]
      [mod.'example.com/shared-pin']
        version = 'v1.0.0-root'
        hash = 'sha256-root'
    EOF
    cat > $out/go/gomod2nix.toml <<'EOF'
    schema = 3

    [mod]
      [mod.'example.com/shared-pin']
        version = 'v1.0.0-module'
        hash = 'sha256-module'
    EOF
    cat > $out/go/go.mod <<'EOF'
    module example.com/both-tomls/go

    go 1.26
    EOF
  '';

  bothTomlsMergedView = mkMergedView {
    pwd = workspaceConsumer;
    modules = null;
    goFlakeInputs = {
      "example.com/both-tomls/go" = {
        src = bothTomlsProducer;
        subPath = "go";
      };
    };
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    inherit parseGoMod;
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "internals-merge-tests"
  {
    _ignored = [
      # #50 regression: bridged keys MUST be stripped from the merged
      # `mod` table, regardless of which side declared them (consumer
      # AND producer entries for the same key are both removed).
      (assert' "bridged key stripped (consumer's pin removed) (#50)"
        (! merged.mod ? "github.com/example/shared"))

      # Non-bridged keys survive unchanged.
      (assert' "non-bridged consumer key kept"
        (merged.mod ? "github.com/example/only-in-consumer"))
      (assert' "non-bridged producer key kept"
        (merged.mod ? "github.com/example/only-in-flake"))

      # Schema preserved from consumer.
      (assert' "schema preserved" (merged.schema == 3))

      # Legacy behaviour without bridgedKeys: nothing stripped,
      # consumer wins on conflict.
      (assert' "no-bridge: shared key kept" (mergedNoBridge.mod ? "github.com/example/shared"))
      (assert' "no-bridge: consumer wins on conflict"
        (mergedNoBridge.mod."github.com/example/shared".hash == "consumer-hash"))

      # #38 sentinelFor unit cases: the major is derived from a trailing
      # /vN (N ≥ 2); everything else keeps the v0 sentinel.
      (assert' "#38 sentinelFor: unsuffixed path keeps v0 sentinel"
        (sentinelFor "github.com/amarbel-llc/tap/go" == v0Sentinel))
      (assert' "#38 sentinelFor: /v2 path gets v2 sentinel"
        (sentinelFor "github.com/amarbel-llc/crap/go-crap/v2"
          == "v2.0.0-00010101000000-000000000000"))
      (assert' "#38 sentinelFor: /v3 path gets v3 sentinel"
        (sentinelFor "example.com/foo/v3" == "v3.0.0-00010101000000-000000000000"))
      (assert' "#38 sentinelFor: multi-digit major /v10"
        (sentinelFor "example.com/foo/v10" == "v10.0.0-00010101000000-000000000000"))
      (assert' "#38 sentinelFor: /v1 is not a real major suffix, keeps v0 sentinel"
        (sentinelFor "example.com/foo/v1" == v0Sentinel))
      (assert' "#38 sentinelFor: /v0 keeps v0 sentinel"
        (sentinelFor "example.com/foo/v0" == v0Sentinel))
      (assert' "#38 sentinelFor: 'v2' as a non-final path component is ignored"
        (sentinelFor "example.com/v2/foo" == v0Sentinel))

      # #45 advisory coverage: exactly one producer has gaps, and the
      # only missing module is the org-prefixed, uncovered, unpinned one.
      (assert' "#45 gaps: one producer reported"
        (builtins.length coverageGaps == 1))
      (assert' "#45 gaps: producer attributed by module path"
        ((builtins.head coverageGaps).producer == "github.com/amarbel-llc/prod/go"))
      (assert' "#45 gaps: covered/pinned/foreign requires excluded, private-dep flagged"
        ((builtins.head coverageGaps).missing == [ "github.com/amarbel-llc/private-dep" ]))

      # #45: producers without a readable go.mod contribute nothing and
      # never throw (pre-modules deps, dangling paths).
      (assert' "#45 gaps: go.mod-less and nonexistent producers are silent"
        (coverageGapsNoGoMod == [ ]))

      # #45 wiring: mkMergedView surfaces coverageGaps. With modules =
      # null nothing is pinned, so pinned-dep joins private-dep in the
      # missing set (attrNames order: pinned-dep sorts first).
      (assert' "#45 mkMergedView: coverageGaps exposed with unpinned toml"
        ((builtins.head coverageMergedView.coverageGaps).missing == [
          "github.com/amarbel-llc/pinned-dep"
          "github.com/amarbel-llc/private-dep"
        ]))

      # #49 workspace-root fallback: the producer's root-lockfile pin
      # reaches the subPath consumer's merged mod table...
      (assert' "#49 fallback: root toml pin transported to subPath consumer"
        (workspaceMergedView.modulesStruct.mod ? "github.com/amarbel-llc/tommy"))
      # ...and the #45 coverage warning self-silences (tommy is pinned).
      (assert' "#49 fallback: coverage warning silenced by transported pin"
        (workspaceMergedView.coverageGaps == [ ]))

      # #49 precedence: a subPath slice with its OWN toml wins over the
      # workspace root's — the module's lockfile is authoritative.
      (assert' "#49 precedence: module-local toml beats workspace root"
        (bothTomlsMergedView.modulesStruct.mod."example.com/shared-pin".version
          == "v1.0.0-module"))
    ];

    # Integration: building forces the real `go mod edit` pipeline.
    inherit mergedV2GoMod mergedOrganicGoMod;
  }
  ''
    echo "=== merged go.mod (#38 /v2 sentinel — no organic require) ==="
    cat "$mergedV2GoMod"
    grep -Eq 'github.com/amarbel-llc/crap/go-crap/v2 v2\.0\.0-00010101000000-000000000000' "$mergedV2GoMod" \
      || { echo "FAIL(#38): /v2 require missing v2 sentinel"; exit 1; }
    grep -Eq 'github.com/amarbel-llc/tap/go v0\.0\.0-00010101000000-000000000000' "$mergedV2GoMod" \
      || { echo "FAIL(#38): non-suffixed require missing v0 sentinel"; exit 1; }

    echo "=== merged go.mod (#39 organic require → real version, NO sentinel) ==="
    cat "$mergedOrganicGoMod"
    grep -Eq 'github.com/amarbel-llc/crap/go-crap/v2 v2\.1\.0' "$mergedOrganicGoMod" \
      || { echo "FAIL(#39): organic require version not preserved"; exit 1; }
    if grep -q '00010101000000' "$mergedOrganicGoMod"; then
      echo "FAIL(#39): sentinel leaked despite an organic require"; exit 1
    fi
    grep -Eq 'replace github.com/amarbel-llc/crap/go-crap/v2 =>' "$mergedOrganicGoMod" \
      || { echo "FAIL(#39): replace directive missing"; exit 1; }

    touch "$out"
  ''
