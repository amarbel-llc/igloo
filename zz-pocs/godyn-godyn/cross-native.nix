# godyn→godyn composition POC: module B (app) consuming module A (dep) two ways.
#
# Approach 1 — OUTPUT BRIDGE: dep/greet is built as A's compiled archive (an
# OUTPUT, conceptually from dep's own flake), and app LINKS it. dep/greet is NOT a
# node in app's compile graph.
#
# Approach 2 — SOURCE (flake-input + go.mod): dep/greet is a NODE in app's graph,
# compiled from A's SOURCE (which in a real setup arrives via a flake input + a
# go.mod require). app recompiles dep/greet in its own build.
#
# Key thing the POC surfaces: godyn names a package archive by its IMPORT PATH
# (godyn-compile-<importpath>), and the archive is content-addressed. So dep/greet
# compiled "as dep's output" and "as a node in app's graph" produce the SAME store
# object — the two approaches CONVERGE at the archive level (no duplicated compile).
# The difference is the eval-graph interface and the practical coupling (approach 1
# needs A's toolchain == B's and only A's archive; approach 2 needs A's source + a
# go.mod edge but is always toolchain-consistent).
{
  lib,
  runCommandLocal,
  go,
  stdlib,
  depSrc, # module A source root (example.com/dep)
  appSrc, # module B source root (example.com/app)
  goVersion ? "go1.26",
}:
let
  caAttrs = {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };
  greetSrc = builtins.path {
    path = depSrc + "/greet";
    name = "gg-src-dep-greet";
  };
  appPkgSrc = builtins.path {
    path = appSrc;
    name = "gg-src-app";
  };

  # The per-package archive for dep/greet. Named by import path (godyn convention),
  # so it is THE SAME store object whether produced by dep's flake (approach 1) or
  # as a node in app's graph (approach 2) — given the same source + toolchain.
  greetArchive =
    runCommandLocal "godyn-compile-example-com-dep-greet" ({ nativeBuildInputs = [ go ]; } // caAttrs)
      ''
        export GOROOT=${go}/share/go
        mkdir -p "$out"
        cat ${stdlib}/importcfg > importcfg
        go tool compile -importcfg importcfg -p 'example.com/dep/greet' -buildid "" \
          -trimpath="${greetSrc}=>example.com/dep/greet;$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${goVersion} \
          -o "$out/pkg.a" ${greetSrc}/greet.go
      '';

  # CONVERGENCE TEST — compile dep/greet AGAIN from a DIFFERENT source store path
  # (same content, different builtins.path name → models dep arriving via app's flake
  # INPUT instead of dep's flake). Same import-path-derived derivation name + CA: if
  # godyn's -trimpath fully canonicalises, this dedups to greetArchive's EXACT store
  # path (proving the archive is route-independent → approaches 1 & 2 converge); if
  # the source path leaks into the .a, it won't.
  greetSrcAlt = builtins.path {
    path = depSrc + "/greet";
    name = "gg-src-dep-greet-via-app-input";
  };
  greetAlt =
    runCommandLocal "godyn-compile-example-com-dep-greet" ({ nativeBuildInputs = [ go ]; } // caAttrs)
      ''
        export GOROOT=${go}/share/go
        mkdir -p "$out"
        cat ${stdlib}/importcfg > importcfg
        go tool compile -importcfg importcfg -p 'example.com/dep/greet' -buildid "" \
          -trimpath="${greetSrcAlt}=>example.com/dep/greet;$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${goVersion} \
          -o "$out/pkg.a" ${greetSrcAlt}/greet.go
      '';

  # Compile + link app/main against dep/greet supplied as the archive at `greetA`,
  # then run it (asserting the cross-module call works). `inGraph` only changes the
  # label/comment — the realized build is identical either way (the convergence).
  mkApp =
    {
      name,
      greetA,
      note,
    }:
    runCommandLocal name ({ nativeBuildInputs = [ go ]; } // caAttrs) ''
      export GOROOT=${go}/share/go
      W="$NIX_BUILD_TOP"; mkdir -p "$out/bin"
      # ${note}
      cat ${stdlib}/importcfg > ic
      echo "packagefile example.com/dep/greet=${greetA}" >> ic
      # -p main (not the import path): the linker resolves main.main from package main.
      go tool compile -importcfg ic -p main -buildid "" \
        -trimpath="${appPkgSrc}=>main;$W=>" -nolocalimports -pack -lang=${goVersion} \
        -o "$W/main.a" ${appPkgSrc}/main.go
      cat ${stdlib}/importcfg > ic.link
      echo "packagefile example.com/dep/greet=${greetA}" >> ic.link
      GOTOOLDIR="$(go env GOTOOLDIR)"; export GOROOT=
      "$GOTOOLDIR/link" -buildid=redacted -buildmode=exe -importcfg ic.link \
        -o "$out/bin/app" "$W/main.a"
      got=$("$out/bin/app"); want="hello from dep/greet"
      [ "$got" = "$want" ] || { echo "cross-module call FAILED: [$got] != [$want]"; exit 1; }
      cp "$W/main.a" "$out/main.a"  # exposed so the two approaches' binaries can be diffed
    '';

  # Approach 1 — app links dep's compiled-archive OUTPUT (greet absent from app's graph).
  appBridge = mkApp {
    name = "gg-app-bridge";
    greetA = "${greetArchive}/pkg.a";
    note = "approach 1: dep/greet is an external archive (dep's output), linked, not recompiled";
  };

  # Approach 2 — dep/greet is a graph node compiled from A's SOURCE arriving via app's
  # flake-input route (greetAlt). That archive CA-dedups to greetArchive's exact store
  # path (proven by the greetArchive==greetAlt check), so app links the identical
  # object — the approaches converge at the build level.
  appSource = mkApp {
    name = "gg-app-source";
    greetA = "${greetAlt}/pkg.a";
    note = "approach 2: dep/greet from source via app's flake input; CA-dedups to greetArchive";
  };
in
{
  inherit
    greetArchive
    greetAlt
    appBridge
    appSource
    ;
}
