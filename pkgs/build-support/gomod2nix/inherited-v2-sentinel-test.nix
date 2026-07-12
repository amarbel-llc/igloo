# Regression test for amarbel-llc/igloo#54 — the chrest→cutting-garden
# goFlakeInputs bridge acceptance case (which fixed chrest#98).
# Build with: nix-build pkgs/build-support/gomod2nix/inherited-v2-sentinel-test.nix
#
# WHAT THIS PINS (the composition no other test exercises end to end):
# a /v2 module that reaches the consumer ONLY through depth-1 passthru
# inheritance — never declared in the consumer's own goFlakeInputs and
# never organically required by the consumer — MUST get a valid v2-major
# sentinel in the merged go.mod, not the v0.0.0 sentinel that failed
# chrest#98 before #38.
#
# The pieces are covered in isolation elsewhere: sentinelFor's /vN unit
# cases and mkMergedGoMod's DIRECT /v2 entry in internals-merge-test.nix,
# depth-1 inheritance (with dummy string paths, no go mod edit) likewise.
# The live chrest→cutting-garden shape is their COMPOSITION through
# mkMergedView: chrest bridges cutting-garden's go-pkgs, whose
# passthru.goFlakeInputs carries crap/go-crap/v2; chrest requires
# cutting-garden organically but never crap/go-crap/v2, so the /v2 module
# flows purely via inheritance onto mkMergedGoMod's synthetic-sentinel
# path. This test reproduces exactly that at the internals layer and runs
# the real `go mod edit` pipeline the original failure hit.
{
  pkgs ? import ../../.. { },
}:
let
  inherit (pkgs.callPackage ./internals.nix { }) mkMergedView;
  inherit (import ./parser.nix) parseGoMod;

  cgModule = "github.com/amarbel-llc/cutting-garden";
  crapV2 = "github.com/amarbel-llc/crap/go-crap/v2";
  v2Sentinel = "v2.0.0-00010101000000-000000000000";

  # `go mod edit -replace` does not require the target to exist on disk,
  # so an empty tree with the subPath dir is enough to assert formatting.
  crapV2Src = pkgs.runCommand "crap-v2-src" { } "mkdir -p $out/go-crap";

  # Producer mirroring cutting-garden's go-pkgs output: a derivation whose
  # passthru.goFlakeInputs bridges a /v2 transitive. mkGoPkgs attaches
  # exactly this shape (see mk-go-pkgs.nix); synthesized directly here to
  # keep the test at the internals layer without a full mkGoPkgs build.
  cuttingGardenGoPkgs =
    pkgs.runCommand "cutting-garden-go-pkgs"
      {
        passthru.goFlakeInputs = {
          ${crapV2} = {
            src = crapV2Src;
            subPath = "go-crap";
          };
        };
      }
      ''
        mkdir -p $out
        cat > $out/go.mod <<'EOF'
        module github.com/amarbel-llc/cutting-garden

        go 1.26
        EOF
      '';

  # Consumer mirroring chrest: bridges cutting-garden, requires it
  # organically, and NEVER mentions crap/go-crap/v2 in its own go.mod.
  consumer = pkgs.runCommand "cg-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26

    require github.com/amarbel-llc/cutting-garden v0.1.24
    EOF
  '';

  merged = mkMergedView {
    pwd = consumer;
    modules = null;
    goFlakeInputs = {
      ${cgModule} = cuttingGardenGoPkgs;
    };
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    inherit parseGoMod;
  };

  consumerRequires = merged.consumerGoMod.require or { };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "inherited-v2-sentinel-test"
  {
    _ignored = [
      # The /v2 module reaches the effective bridge map ONLY via the
      # producer's passthru — the consumer never declared it. (hasAttr,
      # not `?`: the module path is a variable, and `?`'s RHS is a
      # literal attrpath, not an expression.)
      (assert' "igloo#54: inherited /v2 module reaches the effective bridge map" (
        builtins.hasAttr crapV2 merged.normalizedFlakeInputs
      ))
      # ...and the consumer does NOT organically require it, so it takes
      # the synthetic-sentinel path (not the conditional-require path).
      (assert' "igloo#54: consumer does not organically require the inherited /v2 module" (
        !builtins.hasAttr crapV2 consumerRequires
      ))
      # The bridged producer itself IS organically required — it rides the
      # conditional-require (sentinel-free) path, exercising both branches
      # of mkMergedGoMod in the same merge, exactly as chrest does.
      (assert' "igloo#54: consumer organically requires the bridged producer" (
        builtins.hasAttr cgModule consumerRequires
      ))
    ];
    mergedGoMod = merged.mergedGoModFile;
  }
  ''
    echo "=== merged go.mod (igloo#54: inherited /v2 sentinel) ==="
    cat "$mergedGoMod"

    # The chrest#98 regression signal: the inherited /v2 require gets a
    # valid v2-major sentinel.
    grep -Eq 'github.com/amarbel-llc/crap/go-crap/v2 v2\.0\.0-00010101000000-000000000000' "$mergedGoMod" \
      || { echo "FAIL(igloo#54): inherited /v2 require missing v2 sentinel"; exit 1; }

    # The original failure mode: a v0 sentinel on the /v2 path. Its
    # presence is the exact `should be v2, not v0` regression.
    if grep -Eq 'github.com/amarbel-llc/crap/go-crap/v2 v0\.0\.0' "$mergedGoMod"; then
      echo "FAIL(igloo#54): inherited /v2 got the invalid v0 sentinel (chrest#98 regression)"; exit 1
    fi

    # The replace binds the inherited /v2 module to the producer's subtree.
    grep -Eq 'replace github.com/amarbel-llc/crap/go-crap/v2 =>' "$mergedGoMod" \
      || { echo "FAIL(igloo#54): inherited /v2 replace directive missing"; exit 1; }

    # The organically-required producer keeps its real version — no
    # sentinel leaks onto the conditional-require path.
    if grep -E 'github.com/amarbel-llc/cutting-garden' "$mergedGoMod" | grep -q '00010101000000'; then
      echo "FAIL(igloo#54): sentinel leaked onto the organically-required producer"; exit 1
    fi

    touch "$out"
  ''
