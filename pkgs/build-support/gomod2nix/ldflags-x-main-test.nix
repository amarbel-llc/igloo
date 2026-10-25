# Regression test for amarbel-llc/igloo#53: an `ldflagsX` key that names a
# `package main` variable by its real import path (`<module>/cmd/foo.Var`)
# matches no linker symbol — Go only exposes package-main variables as
# `main.Var` — and `go build` ignores the -X silently. buildGoApplication now
# refuses such a key when it can tell: the key's package prefix equals a
# subPackages entry resolved against the organic go.mod's module path.
# Eval-only; no Go toolchain runs.
# Build with: nix-build pkgs/build-support/gomod2nix/ldflags-x-main-test.nix
{
  pkgs ? import ../../.. { },
}:
let
  inherit (pkgs) lib;

  src = pkgs.runCommand "ldflagsx-fixture" { } ''
    mkdir -p $out
    echo "module example.com/x" > $out/go.mod
    echo "go 1.26" >> $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
  '';

  build =
    extra:
    pkgs.buildGoApplication (
      {
        inherit src;
        pwd = src;
        pname = "smoke";
        subPackages = [
          "cmd/foo"
          "."
        ];
      }
      // extra
    );

  refused = extra: !(builtins.tryEval (build extra).drvPath).success;
  accepted =
    extra:
    builtins.elem "-X ${builtins.head (builtins.attrNames extra.ldflagsX)}=1" (build extra).ldflags;

  checks = [
    {
      name = "#53 a key under a cmd/ main package import path is refused";
      ok = refused { ldflagsX."example.com/x/cmd/foo.Var" = "1"; };
    }
    {
      name = "#53 a key under the root main package (subPackages dot) is refused";
      ok = refused { ldflagsX."example.com/x.Var" = "1"; };
    }
    {
      name = "#53 a key under a non-main package is accepted";
      ok = accepted { ldflagsX."example.com/x/internal/cfg.Var" = "1"; };
    }
    {
      name = "#53 the working spelling, main.<Var>, is accepted";
      ok = accepted { ldflagsX."main.Var" = "1"; };
    }
    {
      name = "#53 nothing is refused when subPackages is unknown (all mains)";
      ok = accepted {
        subPackages = null;
        ldflagsX."example.com/x/cmd/foo.Var" = "1";
      };
    }
  ];
  failed = lib.filter (c: !c.ok) checks;
in
if failed != [ ] then
  throw "ldflags-x-main-test: ${lib.concatMapStringsSep "; " (c: "FAIL ${c.name}") failed}"
else
  pkgs.runCommand "ldflags-x-main-test" { } ''
    ${lib.concatMapStringsSep "\n" (c: "echo 'ok ${c.name}'") checks}
    touch $out
  ''
