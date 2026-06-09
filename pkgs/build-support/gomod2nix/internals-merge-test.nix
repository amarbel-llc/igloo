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
    inheritedGoFlakeInputs
    mkMergedGoMod
    sentinelFor
    ;

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

  # #36 fixtures — producer derivations carrying passthru.goFlakeInputs.
  # mkGoPkgs callers attach this passthru on their go-pkgs outputs so
  # downstream consumers' bridge can union the producer's own
  # cross-flake declarations into the merged map at depth-1.
  producerWithPassthru = pkgs.runCommand "producer-with-passthru"
    {
      passthru.goFlakeInputs = {
        "github.com/inherited/from-record-form" = {
          src = "/nix/store/inherited-record";
          subPath = "go";
        };
        "github.com/inherited/from-conflict" = "/nix/store/inherited-conflict";
      };
    }
    "mkdir -p $out";

  producerBareDerivation = pkgs.runCommand "producer-bare"
    {
      passthru.goFlakeInputs = {
        "github.com/inherited/from-bare-producer" = "/nix/store/inherited-bare";
      };
    }
    "mkdir -p $out";

  producerNoPassthru = pkgs.runCommand "producer-no-passthru" { } "mkdir -p $out";

  consumerGoFlakeInputs = {
    # Record-form entry whose .src has passthru.
    "github.com/example/record-producer" = {
      src = producerWithPassthru;
      subPath = "";
    };
    # Bare-derivation entry with passthru directly on it.
    "github.com/example/bare-producer" = producerBareDerivation;
    # Entry whose producer has no passthru — must not error.
    "github.com/example/no-passthru-producer" = producerNoPassthru;
    # Consumer explicitly overrides an inherited entry.
    "github.com/inherited/from-conflict" = "/nix/store/consumer-wins";
  };

  inherited = inheritedGoFlakeInputs consumerGoFlakeInputs;

  # The effective map applied to the bridge: inherited first, consumer
  # entries layered on top — `//` makes consumer the conflict winner.
  effective = inherited // consumerGoFlakeInputs;

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

      # #36 depth-1 passthru inheritance.
      (assert' "#36 inherit: record-form producer's passthru entry surfaces"
        (inherited ? "github.com/inherited/from-record-form"))
      (assert' "#36 inherit: bare-derivation producer's passthru entry surfaces"
        (inherited ? "github.com/inherited/from-bare-producer"))
      (assert' "#36 inherit: producer without passthru contributes nothing"
        (! inherited ? "github.com/example/no-passthru-producer"))
      (assert' "#36 inherit: consumer-declared keys are NOT auto-included in inherited map"
        (! inherited ? "github.com/example/record-producer"))

      # #36 consumer-wins on conflict.
      (assert' "#36 conflict: consumer entry overrides inherited entry in effective map"
        (effective."github.com/inherited/from-conflict" == "/nix/store/consumer-wins"))
      (assert' "#36 conflict: inherited map itself still reflects producer's view"
        (inherited."github.com/inherited/from-conflict" == "/nix/store/inherited-conflict"))

      # #36 depth-1 limit: inheritedGoFlakeInputs MUST NOT recurse into
      # inherited entries' own passthru. The deeper-than-one path is
      # deferred to the FOD-regen work tracked on #36 itself.
      # (Fixture intentionally doesn't add a recursive case — its
      # absence from the result is the test.)
      (assert' "#36 depth-1: only direct producers contribute"
        (builtins.length (builtins.attrNames inherited) == 3))

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
    ];

    # #38 integration: building forces the real `go mod edit` pipeline.
    inherit mergedV2GoMod;
  }
  ''
    echo "=== merged go.mod (#38 /v2 sentinel) ==="
    cat "$mergedV2GoMod"
    grep -Eq 'github.com/amarbel-llc/crap/go-crap/v2 v2\.0\.0-00010101000000-000000000000' "$mergedV2GoMod" \
      || { echo "FAIL(#38): /v2 require missing v2 sentinel"; exit 1; }
    grep -Eq 'github.com/amarbel-llc/tap/go v0\.0\.0-00010101000000-000000000000' "$mergedV2GoMod" \
      || { echo "FAIL(#38): non-suffixed require missing v0 sentinel"; exit 1; }
    touch "$out"
  ''
