# Regression test: workspace-mode CHAINING / embedding (Design A, igloo#39).
# Build with: nix-build pkgs/build-support/gomod2nix/workspace-chaining-test.nix
#
# The real shape this de-risks: dodder bridges madder, and madder ITSELF
# bridges go-crap/v2 + tap. So a workspace-mode consumer must resolve a
# producer's OWN transitively-bridged deps — i.e. depth-1
# `passthru.goFlakeInputs` inheritance must compose with `go work vendor`.
#
# Here: consumer C bridges producer P (and does NOT declare X). P's go.mod
# requires X and P exposes `passthru.goFlakeInputs = { X = <src>; }` (what a
# producer's go-pkgs output carries). mkMergedView must inherit X (depth-1),
# mkGoWorkVendorEnv must emit a `replace` for both P and X, and `go work
# vendor` must vendor the full chain so the build resolves C → P → X.
{
  pkgs ? import ../../.. { },
}:
let
  # Transitive dep, bridged only via P's passthru (never declared by C).
  depX = pkgs.runCommand "chain-dep-x" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/x

    go 1.26
    EOF
    cat > $out/x.go <<'EOF'
    package x

    func Name() string { return "x" }
    EOF
  '';

  # Producer P requires + imports X, and advertises X via passthru
  # goFlakeInputs — the producer-side inheritance the bridge unions at depth-1.
  prodP =
    pkgs.runCommand "chain-prod-p"
      {
        passthru.goFlakeInputs = {
          "example.com/x" = depX;
        };
      }
      ''
        mkdir -p $out
        cat > $out/go.mod <<'EOF'
        module example.com/p

        go 1.26

        require example.com/x v1.0.0
        EOF
        cat > $out/lib.go <<'EOF'
        package p

        import "example.com/x"

        func Greeting() string { return "p/" + x.Name() }
        EOF
      '';

  # Consumer bridges ONLY P; X is inherited from P.passthru.goFlakeInputs.
  consumer = pkgs.runCommand "chain-consumer" { } ''
    mkdir -p $out
    cat > $out/go.mod <<'EOF'
    module example.com/consumer

    go 1.26

    require example.com/p v1.0.0
    EOF
    cat > $out/main.go <<'EOF'
    package main

    import (
    	"fmt"

    	"example.com/p"
    )

    func main() { fmt.Println(p.Greeting()) }
    EOF
    echo 'schema = 3' > $out/gomod2nix.toml
  '';

  app = pkgs.buildGoApplication {
    pname = "chain-test";
    version = "0";
    src = consumer;
    pwd = consumer;
    goFlakeInputs = {
      "example.com/p" = prodP;
    };
    goFlakeInputsMode = "workspace";
  };
in
pkgs.runCommand "workspace-chaining-test" { } ''
  echo "=== running consumer that bridges P; X inherited via P's passthru ==="
  progout="$(${app}/bin/consumer)"
  echo "program output: $progout"
  [ "$progout" = "p/x" ] \
    || { echo "FAIL: chain C->P->X did not resolve (got: $progout)"; exit 1; }
  touch $out
''
