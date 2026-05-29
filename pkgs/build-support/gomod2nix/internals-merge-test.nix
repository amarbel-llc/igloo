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
{ pkgs ? import ../../.. { } }:
let
  inherit (pkgs.callPackage ./internals.nix { })
    mergeGomod2nixTomls
    inheritedGoFlakeInputs
    ;

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
    ];
  }
  "touch $out"
