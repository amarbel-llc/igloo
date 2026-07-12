# Integration test for buildGoApplication's goFlakeInputs workspace mode
# (Design A, amarbel-llc/igloo#39).
# Build with: nix-build pkgs/build-support/gomod2nix/workspace-mode-test.nix
#
# A consumer bridges a /v2 producer via `goFlakeInputs` + the
# `goFlakeInputsMode = "workspace"` opt-in. The builder (mkGoWorkVendorEnv)
# synthesizes a go.work of `use .` + `replace <producer> => <store>` and runs
# `go work vendor` to generate vendor/ + modules.txt. The consumer keeps its
# organic `require example.com/prod/v2 v2.1.0` — a real /v2 version, NO
# sentinel; the producer's identity comes from its own go.mod. (A versioned
# require for a `use`d member would fail — see igloo#39 — which is why
# producers are `replace`d, not `use`d, in this model.)
#
# Builds end-to-end and runs the binary: success requires the /v2 import to
# have resolved + vendored through `go work vendor`. Leaf producer (no
# external deps) keeps it offline; external-dep + version-skew reconciliation
# is exercised by the madder tracer (igloo#39).
{
  pkgs ? import ../../.. { },
}:
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

  # Consumer organically requires the /v2 producer (the real-consumer case);
  # the go.work `replace` redirects that require to the producer source. No
  # sentinel — v2.1.0 is the consumer's own declared version.
  consumer = pkgs.runCommand "gowork-test-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26

    require example.com/prod/v2 v2.1.0
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
