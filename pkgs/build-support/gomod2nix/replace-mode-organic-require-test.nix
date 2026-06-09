# Integration test: REPLACE mode (default) drops the sentinel when the
# consumer organically requires a bridged /v2 module (Design A, igloo#39).
# Build with: nix-build pkgs/build-support/gomod2nix/replace-mode-organic-require-test.nix
#
# The sentinel-elimination on the DEFAULT path: mkMergedGoMod injects the
# synthetic `require` only for modules the consumer doesn't already require.
# Here the consumer organically `require`s example.com/prod/v2 v2.1.0, so the
# merged go.mod keeps that real version (NO sentinel) and only adds the
# replace. Uses the proven replace-mode vendor (no go work vendor). Builds +
# runs the binary, and asserts passthru.mergedGoMod is sentinel-free.
{ pkgs ? import ../../.. { } }:
let
  prodV2 = pkgs.runCommand "rmo-prod-v2" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/prod/v2

    go 1.26
    EOF
    cat > $out/lib.go <<'EOF'
    package prod

    func Greeting() string { return "hello from /v2 via replace mode, no sentinel" }
    EOF
  '';

  consumer = pkgs.runCommand "rmo-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26

    require example.com/prod/v2 v2.1.0
    EOF
    touch $out/go.sum
    echo 'schema = 3' > $out/gomod2nix.toml
    cat > $out/main.go <<'EOF'
    package main

    import (
    	"fmt"

    	prod "example.com/prod/v2"
    )

    func main() { fmt.Println(prod.Greeting()) }
    EOF
  '';

  app = pkgs.buildGoApplication {
    pname = "rmo-test";
    version = "0";
    src = consumer;
    pwd = consumer;
    goFlakeInputs = {
      "example.com/prod/v2" = prodV2;
    };
    # goFlakeInputsMode defaults to "replace"
  };
in
pkgs.runCommand "replace-mode-organic-require-test"
  {
    mergedGoMod = app.passthru.mergedGoMod;
  }
  ''
    echo "=== merged go.mod (replace mode, organic require) ==="
    cat "$mergedGoMod"
    grep -Eq 'example.com/prod/v2 v2\.1\.0' "$mergedGoMod" \
      || { echo "FAIL: organic require version not preserved"; exit 1; }
    if grep -q '00010101000000' "$mergedGoMod"; then
      echo "FAIL: sentinel leaked despite organic require"; exit 1
    fi

    echo "=== running replace-mode /v2 organic-require binary ==="
    progout="$(${app}/bin/consumer)"
    echo "program output: $progout"
    [ "$progout" = "hello from /v2 via replace mode, no sentinel" ] \
      || { echo "FAIL: unexpected output"; exit 1; }
    touch "$out"
  ''
