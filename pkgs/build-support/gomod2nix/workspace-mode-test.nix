# Integration test for buildGoApplication's goFlakeInputs workspace mode
# (Design A, amarbel-llc/igloo#39).
# Build with: nix-build pkgs/build-support/gomod2nix/workspace-mode-test.nix
#
# A consumer bridges a /v2 producer via `goFlakeInputs` + the
# `goFlakeInputsMode = "workspace"` opt-in. The builder synthesizes a
# go.work overlay (mkMergedGoWork) that `use`s the producer from source —
# the consumer's go.mod gets NO require/replace/sentinel. The producer's /v2
# identity comes from its own go.mod, so the require-sentinel major-mismatch
# that #38 worked around cannot arise in this mode at all.
#
# This builds end-to-end and runs the binary: success requires the /v2
# import to have resolved through the workspace. Leaf producer (no external
# deps) keeps the build offline and fast; external-dep vendoring composes
# via the existing mkVendorEnv/mkWorkspaceModulesTxt path (#39 spikes).
{ pkgs ? import ../../.. { } }:
let
  prodV2 = pkgs.runCommand "gowork-test-prod-v2" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/prod/v2

    go 1.26
    EOF
    cat > $out/lib.go <<'EOF'
    package prod

    func Greeting() string { return "hello from /v2 via workspace mode" }
    EOF
  '';

  # Consumer imports the /v2 producer; its go.mod has NO require/replace for
  # it — the synthesized go.work is the only thing that pulls it in.
  consumer = pkgs.runCommand "gowork-test-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26
    EOF
    cat > $out/main.go <<'EOF'
    package main

    import (
    	"fmt"

    	prod "example.com/prod/v2"
    )

    func main() { fmt.Println(prod.Greeting()) }
    EOF
    echo 'schema = 3' > $out/gomod2nix.toml
  '';

  app = pkgs.buildGoApplication {
    pname = "gowork-test";
    version = "0";
    src = consumer;
    pwd = consumer;
    goFlakeInputs = {
      "example.com/prod/v2" = prodV2;
    };
    goFlakeInputsMode = "workspace";
  };
in
pkgs.runCommand "workspace-mode-test" { } ''
  echo "=== running workspace-bridged binary (proves /v2 resolved sentinel-free) ==="
  progout="$(${app}/bin/consumer)"
  echo "program output: $progout"
  [ "$progout" = "hello from /v2 via workspace mode" ] \
    || { echo "FAIL: unexpected output"; exit 1; }
  touch $out
''
