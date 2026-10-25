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
    go_1_26_10
    go_1_27_3
    mkGoToolchain
    ;
  bundle = mkGoToolchain { };
  pinned = mkGoToolchain { version = "1.26.3"; };
  registry = import ./registry.nix;

  # Every registry entry must resolve through mkGoToolchain, i.e. its Go minor
  # must have a nixpkgs base in default.nix's `bases` (or be a fork entry). The
  # 1.27.3 registration (igloo#89) failed at first build for want of the 1.27
  # base; this makes that an eval-test failure instead.
  baseChecks = map (e: {
    name = "registry ${e.version} has a nixpkgs base (bases in default.nix)";
    ok = (mkGoToolchain { inherit (e) version; }).go.version == e.version;
  }) registry;

  checks = baseChecks ++ [
    {
      name = "goToolchain.go = newest (1.27.3)";
      ok = goToolchain.go.version == "1.27.3";
    }
    {
      name = "goToolchain.go is the go_1_27_3 derivation";
      ok = goToolchain.go.drvPath == go_1_27_3.drvPath;
    }
    {
      name = "go_1_26_10 still present (the previous default; consumers may pin it)";
      ok = go_1_26_10.version == "1.26.10";
    }
    {
      name = "the 1.27 entry builds on a different nixpkgs base than the 1.26 entries";
      ok = go_1_27_3.drvPath != go_1_26_10.drvPath;
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
