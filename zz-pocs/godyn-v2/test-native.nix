# godyn test-support POC — per-package `go test` on the eval-time graph.
#
# Proves the merkle-delta extends to tests: each package's test binary+run is its
# own derivation, so nix re-runs only the changed cone's tests (vs `go test ./...`
# rerunning the whole module). See zz-pocs/godyn-v2/RESEARCH-test-support.md.
#
# Per `go test -c` (ground-truthed), a tested package P needs: a TEST-VARIANT
# compile (P's sources + in-package _test.go, same import path), an EXTERNAL test
# pkg (P_test, imports the test-variant), a TESTMAIN (the go-generated _testmain.go,
# captured under _testmains/), then link → P.test → run it (exit 0 = pass). The POC
# folds those four compiles+link+run into ONE derivation per package; the
# cross-package cache boundary is the separate normal `pkgDrvs` (interpolated as
# store paths == inputDrvs), exactly as native.nix wires the build graph.
{
  lib,
  runCommandLocal,
  go,
  stdlib,
  src, # the test-poc module source root
  goVersion ? "go1.26",
}:
let
  mod = "example.com/gtp";
  sanitize = s: lib.replaceStrings [ "/" "." "_" ] [ "-" "-" "-" ] s;
  # Source ONLY the listed files. Critical for the finer merkle-delta: the normal
  # compile sources just its non-test .go, so editing a _test.go leaves the normal
  # archive's input (hence output) unchanged → dependents' tests stay cached. A test
  # edit in a foundational package then re-runs only THAT package's test, not every
  # dependent's. (native.nix sources the whole dir; here we filter for test-awareness.)
  srcOf = dir: fs: builtins.path {
    path = src + "/${dir}";
    name = "gtp-src-${sanitize dir}";
    filter = p: t: t == "directory" || lib.elem (baseNameOf p) fs;
  };
  # The captured, committed testmains (go-invisible _ dir). This is the "capture
  # route": go list -test already generated them; re-capture only when test funcs
  # change (same generate-commit contract as graph.json).
  testmains = builtins.path {
    path = src + "/_testmains";
    name = "gtp-testmains";
  };
  caAttrs = {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };
  files = srcD: fs: lib.concatMapStringsSep " " (f: "${srcD}/${f}") fs;
  pkgLine = cfg: d: ''echo "packagefile ${d.ip}=${d.drv}/pkg.a" >> ${cfg}'';

  # Normal per-package archive — the cross-package cache boundary. Compiles only the
  # non-test sources, so editing a _test.go leaves this byte-identical (CA) and
  # dependents stay cached.
  normal =
    {
      ip,
      dir,
      goFiles,
      deps ? [ ],
    }:
    let srcD = srcOf dir goFiles;
    in
    runCommandLocal "gtp-compile-${sanitize ip}" ({ nativeBuildInputs = [ go ]; } // caAttrs) ''
      export GOROOT=${go}/share/go
      mkdir -p "$out"
      cat ${stdlib}/importcfg > importcfg
      ${lib.concatMapStringsSep "\n" (pkgLine "importcfg") deps}
      go tool compile -importcfg importcfg -p '${ip}' -buildid "" \
        -trimpath="${srcD}=>${ip};$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${goVersion} \
        -o "$out/pkg.a" ${files srcD goFiles}
    '';

  # One CA derivation per tested package: test-variant + external + testmain compile,
  # link the .test binary, run it. A failing test (nonzero exit) fails the build.
  # `deps` are the test-variant's NORMAL (non-stdlib) imports — interpolated store
  # paths, so they are this derivation's inputDrvs and drive cone re-runs.
  testRun =
    {
      ip,
      short,
      dir,
      goFiles,
      testGoFiles,
      xTestGoFiles ? [ ],
      deps ? [ ],
    }:
    let
      hasExt = xTestGoFiles != [ ];
      extLine = lib.optionalString hasExt ''echo "packagefile ${ip}_test=$W/xtest.a" >> "$CFG"'';
      # The test deriv DOES source the test files (the variant/external need them);
      # editing a test file re-runs this test, but not the normal compile above.
      srcD = srcOf dir (goFiles ++ testGoFiles ++ xTestGoFiles);
    in
    runCommandLocal "gtp-test-${sanitize ip}" ({ nativeBuildInputs = [ go ]; } // caAttrs) ''
      export GOROOT=${go}/share/go
      W="$NIX_BUILD_TOP"; mkdir -p "$out"

      # 1. test-variant: package sources + in-package _test.go, same import path.
      CFG="$W/ic.variant"; cat ${stdlib}/importcfg > "$CFG"
      ${lib.concatMapStringsSep "\n" (pkgLine ''"$CFG"'') deps}
      go tool compile -importcfg "$CFG" -p '${ip}' -buildid "" \
        -trimpath="${srcD}=>${ip};$W=>" -nolocalimports -pack -lang=${goVersion} \
        -o "$W/variant.a" ${files srcD (goFiles ++ testGoFiles)}

      ${lib.optionalString hasExt ''
        # 2. external test package (P_test): imports the TEST-VARIANT at ip.
        CFG="$W/ic.ext"; cat ${stdlib}/importcfg > "$CFG"
        echo "packagefile ${ip}=$W/variant.a" >> "$CFG"
        go tool compile -importcfg "$CFG" -p '${ip}_test' -buildid "" \
          -trimpath="${srcD}=>${ip}_test;$W=>" -nolocalimports -pack -lang=${goVersion} \
          -o "$W/xtest.a" ${files srcD xTestGoFiles}
      ''}

      # 3. testmain (go-generated, captured): imports the variant (+ external) at ip.
      CFG="$W/ic.main"; cat ${stdlib}/importcfg > "$CFG"
      echo "packagefile ${ip}=$W/variant.a" >> "$CFG"
      ${extLine}
      go tool compile -importcfg "$CFG" -p main -buildid "" \
        -trimpath="${testmains}=>;$W=>" -nolocalimports -pack -lang=${goVersion} \
        -o "$W/testmain.a" ${testmains}/${short}.go

      # 4. link the test binary (importcfg.link maps variant + external + normal deps).
      CFG="$W/ic.link"; cat ${stdlib}/importcfg > "$CFG"
      echo "packagefile ${ip}=$W/variant.a" >> "$CFG"
      ${extLine}
      ${lib.concatMapStringsSep "\n" (pkgLine ''"$CFG"'') deps}
      GOTOOLDIR="$(go env GOTOOLDIR)"; export GOROOT=
      "$GOTOOLDIR/link" -buildid=redacted -buildmode=exe -importcfg "$CFG" \
        -o "$W/${short}.test" "$W/testmain.a"

      # 5. run; a failing test fails the build. Deterministic $out for clean CA.
      if "$W/${short}.test" > "$W/log" 2>&1; then
        echo "ok ${ip}" > "$out/result"
      else
        echo "FAIL ${ip}:"; cat "$W/log"; exit 1
      fi
    '';

  leafNormal = normal {
    ip = "${mod}/leaf";
    dir = "leaf";
    goFiles = [ "leaf.go" ];
  };
  midNormal = normal {
    ip = "${mod}/mid";
    dir = "mid";
    goFiles = [ "mid.go" ];
    deps = [ { ip = "${mod}/leaf"; drv = leafNormal; } ];
  };

  leafTest = testRun {
    ip = "${mod}/leaf";
    short = "leaf";
    dir = "leaf";
    goFiles = [ "leaf.go" ];
    testGoFiles = [ "leaf_test.go" ];
    xTestGoFiles = [ "leaf_ext_test.go" ];
  };
  midTest = testRun {
    ip = "${mod}/mid";
    short = "mid";
    dir = "mid";
    goFiles = [ "mid.go" ];
    testGoFiles = [ "mid_test.go" ];
    deps = [ { ip = "${mod}/leaf"; drv = leafNormal; } ];
  };

  # `go test ./...` equivalent: a manifest depending on every package's test run.
  # Building it runs them all (nix parallelises + caches).
  checkAll = runCommandLocal "gtp-test-all" { } ''
    mkdir -p "$out"
    cat ${leafTest}/result >> "$out/results"
    cat ${midTest}/result >> "$out/results"
  '';
in
{
  inherit
    leafNormal
    midNormal
    leafTest
    midTest
    checkAll
    ;
}
