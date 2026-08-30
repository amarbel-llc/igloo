# Eval-test for the go-toolchain overlay (go-toolchain(7)). Asserts the
# registry-driven attrs and the mkGoToolchain bundle resolve correctly WITHOUT
# compiling a Go toolchain from source — so it is a cheap gate. That the newest
# version actually builds is verified out of band (the compiler build is
# deliberately kept off the pre-merge gate; see go-toolchain(7) § CACHING).
#
# Build: nix-build pkgs/development/compilers/go-toolchain/go-toolchain-test.nix
{
  pkgs ? import ../../../.. { },
}:
let
  inherit (pkgs)
    lib
    go
    go_1_26_3
    go_1_26_6
    mkGoToolchain
    ;
  bundle = mkGoToolchain { };
  pinned = mkGoToolchain { version = "1.26.3"; };

  checks = [
    {
      name = "go = newest (1.26.6)";
      ok = go.version == "1.26.6";
    }
    {
      name = "go_1_26_3 coexists at 1.26.3";
      ok = go_1_26_3.version == "1.26.3";
    }
    {
      name = "go_1_26_6 present at 1.26.6";
      ok = go_1_26_6.version == "1.26.6";
    }
    {
      name = "versions coexist as distinct derivations";
      ok = go_1_26_3.drvPath != go_1_26_6.drvPath;
    }
    {
      name = "bundle default go = newest go";
      ok = bundle.go.drvPath == go.drvPath;
    }
    {
      name = "pinned bundle go = go_1_26_3";
      ok = pinned.go.drvPath == go_1_26_3.drvPath;
    }
    {
      name = "bundle exposes buildGoModule";
      ok = bundle ? buildGoModule;
    }
    {
      name = "bundle.buildGoApplication is a function";
      ok = lib.isFunction bundle.buildGoApplication;
    }
    {
      name = "bundle.mkGoEnv is a function";
      ok = lib.isFunction bundle.mkGoEnv;
    }
  ];

  failures = builtins.filter (c: !c.ok) checks;
in
if failures == [ ] then
  pkgs.runCommandLocal "go-toolchain-test-ok" { } "echo OK > $out"
else
  throw "go-toolchain-test failed: ${builtins.concatStringsSep ", " (map (c: c.name) failures)}"
