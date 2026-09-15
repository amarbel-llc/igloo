# Eval-test for the go-toolchain overlay (go-toolchain(7)). Asserts the
# registry-driven attrs and the mkGoToolchain bundle resolve correctly WITHOUT
# compiling a Go toolchain from source — so it is a cheap gate. That the newest
# version actually builds is verified out of band (the compiler build is
# deliberately kept off the pre-merge gate; see go-toolchain(7) § CACHING).
# That nixpkgs' `go` is untouched is the flake check `go-toolchain-scope`,
# which can compare against nixpkgs without the overlay.
#
# Build: nix-build pkgs/development/compilers/go-toolchain/go-toolchain-test.nix
{
  pkgs ? import ../../../.. { },
}:
let
  inherit (pkgs)
    lib
    goToolchain
    go_1_26_3
    go_1_26_6
    go_1_26_8
    mkGoToolchain
    ;
  bundle = mkGoToolchain { };
  pinned = mkGoToolchain { version = "1.26.3"; };

  checks = [
    {
      name = "goToolchain.go = newest (1.26.8)";
      ok = goToolchain.go.version == "1.26.8";
    }
    {
      name = "goToolchain.go is the go_1_26_8 derivation";
      ok = goToolchain.go.drvPath == go_1_26_8.drvPath;
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
      name = "bundle default go = goToolchain.go";
      ok = bundle.go.drvPath == goToolchain.go.drvPath;
    }
    {
      name = "pinned bundle go = go_1_26_3";
      ok = pinned.go.drvPath == go_1_26_3.drvPath;
    }
    {
      name = "goToolchain exposes buildGoModule";
      ok = goToolchain ? buildGoModule;
    }
    {
      name = "goToolchain.buildGoApplication is a function";
      ok = lib.isFunction goToolchain.buildGoApplication;
    }
    {
      name = "goToolchain.mkGoEnv is a function";
      ok = lib.isFunction goToolchain.mkGoEnv;
    }
  ];

  failures = builtins.filter (c: !c.ok) checks;
in
if failures == [ ] then
  pkgs.runCommandLocal "go-toolchain-test-ok" { } "echo OK > $out"
else
  throw "go-toolchain-test failed: ${builtins.concatStringsSep ", " (map (c: c.name) failures)}"
