# Parity test: mkGoEnv in goFlakeInputs workspace mode (Design A, igloo#39).
# Build with: nix-build pkgs/build-support/gomod2nix/mkgoenv-workspace-test.nix
#
# mkGoEnv must accept goFlakeInputsMode = "workspace" and build a devshell
# env whose vendorEnv is workspace-shaped (no synthetic replace symlinks),
# and expose the synthesized go.work as passthru.mergedGoWork so consumers
# can materialize it (shellHook `cp`) for gopls/go to resolve the bridge —
# the workspace-mode analog of passthru.mergedGoMod.
{ pkgs ? import ../../.. { } }:
let
  prodV2 = pkgs.runCommand "mkgoenv-test-prod-v2" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/prod/v2

    go 1.26
    EOF
    echo "package prod" > $out/lib.go
  '';

  consumer = pkgs.runCommand "mkgoenv-test-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26
    EOF
    echo 'schema = 3' > $out/gomod2nix.toml
  '';

  env = pkgs.mkGoEnv {
    pwd = consumer;
    goFlakeInputs = {
      "example.com/prod/v2" = prodV2;
    };
    goFlakeInputsMode = "workspace";
  };
in
pkgs.runCommand "mkgoenv-workspace-test"
  {
    goEnv = env;
    goWork = env.passthru.mergedGoWork;
  }
  ''
    echo "=== mkGoEnv (workspace mode) built: $goEnv ==="
    test -x "$goEnv/bin/go" || { echo "FAIL: env missing go wrapper"; exit 1; }

    echo "=== passthru.mergedGoWork ==="
    cat "$goWork"
    grep -q 'use (' "$goWork" || { echo "FAIL: no use block"; exit 1; }
    grep -q 'mkgoenv-test-prod-v2' "$goWork" \
      || { echo "FAIL: producer not in go.work use block"; exit 1; }
    # Sentinel-free: workspace overlay carries no synthetic version.
    grep -q 'v0.0.0' "$goWork" && { echo "FAIL: sentinel leaked into go.work"; exit 1; }

    touch $out
  ''
