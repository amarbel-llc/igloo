# Regression test for amarbel-llc/igloo#77 (related finding): buildGoApplication
# sets `inherit (go) GOOS GOARCH;` AFTER the caller's attrs, so a caller passing
# `GOARCH = "arm64"` silently got the host arch. A cross build is selected by
# the `go` toolchain (pkgsCross.<platform>.buildPackages.goToolchain.go), never
# by GOOS/GOARCH attrs, so a disagreeing attr is now an eval error instead of a
# silently ignored one. Eval-only; no Go toolchain runs.
# Build with: nix-build pkgs/build-support/gomod2nix/goos-goarch-override-test.nix
{
  pkgs ? import ../../.. { },
}:
let
  inherit (pkgs) lib;

  src = pkgs.runCommand "goos-fixture" { } ''
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
      }
      // extra
    );

  hostArch = pkgs.goToolchain.go.GOARCH;
  otherArch = if hostArch == "arm64" then "amd64" else "arm64";

  plain = build { };
  matching = build {
    GOOS = pkgs.goToolchain.go.GOOS;
    GOARCH = hostArch;
  };
  wrongArch = builtins.tryEval (build { GOARCH = otherArch; }).drvPath;
  wrongOS = builtins.tryEval (build { GOOS = "plan9"; }).drvPath;

  checks = [
    {
      name = "#77 no GOOS/GOARCH attrs: the toolchain values are set";
      ok = plain.GOARCH == hostArch && plain.GOOS == pkgs.goToolchain.go.GOOS;
    }
    {
      name = "#77 attrs equal to the toolchain values are accepted";
      ok = matching.GOARCH == hostArch;
    }
    {
      name = "#77 a GOARCH that disagrees with the toolchain is an eval error, not silently overridden";
      ok = !wrongArch.success;
    }
    {
      name = "#77 a GOOS that disagrees with the toolchain is an eval error";
      ok = !wrongOS.success;
    }
  ];
  failed = lib.filter (c: !c.ok) checks;
in
if failed != [ ] then
  throw "goos-goarch-override-test: ${lib.concatMapStringsSep "; " (c: "FAIL ${c.name}") failed}"
else
  pkgs.runCommand "goos-goarch-override-test" { } ''
    ${lib.concatMapStringsSep "\n" (c: "echo 'ok ${c.name}'") checks}
    touch $out
  ''
