# Regression test: workspace mode with a replace target that has NO go.mod
# (a pre-modules dependency), Design A / amarbel-llc/igloo#39.
# Build with: nix-build pkgs/build-support/gomod2nix/workspace-pre-modules-test.nix
#
# `go work vendor` requires every directory replace-target to carry a go.mod.
# Pre-modules deps (e.g. github.com/dsnet/compress, a 2017 pseudo-version)
# ship none — surfaced by the madder gowork tracer. mkGoWorkVendorEnv's
# ensureGoMod synthesizes a minimal `module <path>` go.mod over a symlink
# farm of the source so `go work vendor` accepts it. This bridges a producer
# whose source deliberately has NO go.mod and asserts the build succeeds.
{
  pkgs ? import ../../.. { },
}:
let
  # Producer source with a package but NO go.mod (simulates a pre-modules
  # dependency as fetched into the store).
  preModules = pkgs.runCommand "premod-no-gomod" { } ''
    mkdir -p $out
    cat > $out/lib.go <<'EOF'
    package premod

    func Tag() string { return "premod-ok" }
    EOF
    echo "# pre-modules dep, no go.mod" > $out/README.md
  '';

  consumer = pkgs.runCommand "premod-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26

    require example.com/premod v1.0.0
    EOF
    cat > $out/main.go <<'EOF'
    package main

    import (
    	"fmt"

    	"example.com/premod"
    )

    func main() { fmt.Println(premod.Tag()) }
    EOF
    echo 'schema = 3' > $out/gomod2nix.toml
  '';

  app = pkgs.buildGoApplication {
    pname = "premod-test";
    version = "0";
    src = consumer;
    pwd = consumer;
    goFlakeInputs = {
      "example.com/premod" = preModules;
    };
    goFlakeInputsMode = "workspace";
  };
in
pkgs.runCommand "workspace-pre-modules-test" { } ''
  echo "=== running binary bridged through a no-go.mod replace target ==="
  progout="$(${app}/bin/consumer)"
  echo "program output: $progout"
  [ "$progout" = "premod-ok" ] \
    || { echo "FAIL: unexpected output"; exit 1; }
  touch $out
''
