# Validation tests for `buildGoApplication` / `mkGoEnv` pwd handling.
# Build with: nix-build pkgs/build-support/gomod2nix/pwd-validation-test.nix
#
# Both helpers historically accepted a null/missing `pwd` and limped
# along with broken downstream behavior (vendor-env crash, opaque
# error elsewhere). This test pins the eval-time validation that
# catches the footgun before any build kicks off.
#
# Failures the validation MUST surface:
#   1. Neither `pwd` nor `src` given (no anchor at all)
#   2. `pwd` (or src-defaulted-pwd) points at a directory with no
#      go.mod and no go.work (polyglot case: caller passed the repo
#      root instead of the go/ subdir)
{
  pkgs ? import ../../.. { },
}:
let
  # Minimal valid single-module fixture: a directory with go.mod.
  withGoMod = pkgs.runCommand "pwd-fixture-with-go-mod" { } ''
    mkdir -p $out
    echo "module example.com/x" > $out/go.mod
    echo "go 1.26" >> $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
  '';

  # Polyglot fixture: root has no go.mod, go.mod lives at ./go.
  polyglotRoot = pkgs.runCommand "pwd-fixture-polyglot" { } ''
    mkdir -p $out/go
    echo "module example.com/x/go" > $out/go/go.mod
    echo "go 1.26" >> $out/go/go.mod
    touch $out/go/go.sum
    touch $out/go/gomod2nix.toml
    echo "# README" > $out/README.md
  '';

  # Force a derivation's eval by reading .name — surfaces eval-time
  # throws via tryEval's success flag.
  tryDrv = drv: builtins.tryEval drv.name;

  # --- buildGoApplication cases ---

  # FAIL: no pwd, no src → can't infer anything.
  bgaNoAnchor = tryDrv (pkgs.buildGoApplication { });

  # FAIL: src given but it doesn't contain go.mod/go.work (the
  # polyglot footgun — caller passes the repo root instead of the
  # `go/` subdir).
  bgaSrcNoGoMod = tryDrv (
    pkgs.buildGoApplication {
      src = polyglotRoot;
    }
  );

  # SUCCEED: single-module src — pwd defaults to src.
  bgaSrcOnly = tryDrv (
    pkgs.buildGoApplication {
      src = withGoMod;
      pname = "smoke";
      version = "0";
    }
  );

  # SUCCEED: explicit pwd pointing at the polyglot subdir.
  bgaPolyglot = tryDrv (
    pkgs.buildGoApplication {
      src = polyglotRoot;
      pwd = polyglotRoot + "/go";
      pname = "smoke";
      version = "0";
    }
  );

  # --- mkGoEnv cases ---

  # FAIL: pwd lacks go.mod/go.work.
  envBadPwd = tryDrv (
    pkgs.mkGoEnv {
      pwd = polyglotRoot;
    }
  );

  # SUCCEED: pwd pointing at the polyglot go/ subdir.
  envGood = tryDrv (
    pkgs.mkGoEnv {
      pwd = polyglotRoot + "/go";
    }
  );

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "pwd-validation-tests" {
  _ignored = [
    # buildGoApplication validations
    (assert' "bga: throws when neither pwd nor src given" (!bgaNoAnchor.success))
    (assert' "bga: throws when src lacks go.mod (polyglot footgun)" (!bgaSrcNoGoMod.success))
    (assert' "bga: succeeds when src has go.mod (pwd defaults to src)" bgaSrcOnly.success)
    (assert' "bga: succeeds with explicit polyglot pwd" bgaPolyglot.success)

    # mkGoEnv validations
    (assert' "mkGoEnv: throws when pwd lacks go.mod/go.work" (!envBadPwd.success))
    (assert' "mkGoEnv: succeeds when pwd has go.mod" envGood.success)
  ];
} "touch $out"
