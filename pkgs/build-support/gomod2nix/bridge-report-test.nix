# Regression test for amarbel-llc/igloo#56 (bridge capability signal) and
# #57 (bridge report): mkMergedView.bridgeReport is a pure-eval surface —
# the capability version/features plus a per-module report (provenance,
# sentinel-vs-organic, subPath) and coverage gaps — that both
# buildGoApplication and mkGoEnv expose as passthru.bridge.
# Build with: nix-build pkgs/build-support/gomod2nix/bridge-report-test.nix
#
# The fixture covers all three per-module shapes in one merge:
#   - inherited (depth-1), not organically required -> synthetic v2 sentinel
#   - consumer-declared, organically required        -> no sentinel (organic kept)
#   - consumer-declared, NOT organically required    -> synthetic v0 sentinel
{ pkgs ? import ../../.. { } }:
let
  inherit (pkgs.callPackage ./internals.nix { }) mkMergedView bridgeCapabilities;
  inherit (import ./parser.nix) parseGoMod;

  cgModule = "github.com/amarbel-llc/cutting-garden";
  crapV2 = "github.com/amarbel-llc/crap/go-crap/v2";
  extra = "example.com/extra";
  v0Sentinel = "v0.0.0-00010101000000-000000000000";
  v2Sentinel = "v2.0.0-00010101000000-000000000000";

  crapV2Src = pkgs.runCommand "crap-v2-src" { } "mkdir -p $out/go-crap";
  extraSrc = pkgs.runCommand "extra-src" { } "mkdir -p $out";

  # Producer mirroring cutting-garden's go-pkgs: carries an inherited /v2
  # transitive in passthru.goFlakeInputs (depth-1 inheritance source).
  cuttingGardenGoPkgs = pkgs.runCommand "cutting-garden-go-pkgs"
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

  # Consumer organically requires cutting-garden, but NOT example.com/extra
  # (declared-but-unimported) nor crap/go-crap/v2 (inherited).
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
      ${extra} = extraSrc;
    };
    go = pkgs.go;
    runCommand = pkgs.runCommand;
    inherit parseGoMod;
  };

  report = merged.bridgeReport;
  mods = report.modules;

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "bridge-report-test"
  {
    _ignored = [
      # #56 capability signal.
      (assert' "#56: report carries the capability version (== constant, == 1)"
        (report.version == bridgeCapabilities.version && report.version == 1))
      (assert' "#56: features advertise the #55 failure annotation"
        (builtins.elem "failure-annotation" report.features))
      (assert' "#56: features advertise the #38 per-vn sentinel"
        (builtins.elem "per-vn-sentinel" report.features))
      (assert' "#57: mode reported" (report.mode == "replace"))

      # #56 overlay-level exposure: pkgs.bridgeCapabilities surfaces the same
      # constant (the pre-adoption query path — no build, no consumer bridge).
      (assert' "#56: overlay exposes pkgs.bridgeCapabilities"
        (pkgs.bridgeCapabilities.version == 1
          && builtins.elem "failure-annotation" pkgs.bridgeCapabilities.features))

      # #57 inherited /v2, not organically required: inherited provenance,
      # synthetic v2 sentinel, subPath surfaced.
      (assert' "#57: inherited /v2 provenance" (mods.${crapV2}.provenance == "inherited"))
      (assert' "#57: inherited /v2 not organically required"
        (mods.${crapV2}.organicRequire == false))
      (assert' "#57: inherited /v2 gets the v2 sentinel" (mods.${crapV2}.sentinel == v2Sentinel))
      (assert' "#57: inherited /v2 subPath reported" (mods.${crapV2}.subPath == "go-crap"))

      # #57 consumer-declared producer, organically required: no sentinel.
      (assert' "#57: declared+organic provenance" (mods.${cgModule}.provenance == "declared"))
      (assert' "#57: declared+organic is organically required"
        (mods.${cgModule}.organicRequire == true))
      (assert' "#57: declared+organic keeps its version (no sentinel)"
        (mods.${cgModule}.sentinel == null))

      # #57 consumer-declared but NOT organically required: v0 sentinel.
      (assert' "#57: declared non-organic provenance" (mods.${extra}.provenance == "declared"))
      (assert' "#57: declared non-organic gets a sentinel" (mods.${extra}.sentinel == v0Sentinel))

      # Clean fixture -> no coverage gaps.
      (assert' "#57: coverageGaps empty for a clean fixture" (report.coverageGaps == [ ]))
    ];
  }
  ''
    touch $out
  ''
