# Version-embedding tests for `buildGoApplication`'s version.env auto-read
# (amarbel-llc/nixpkgs#31). Build with:
#   nix-build pkgs/build-support/gomod2nix/version-env-test.nix
#
# The builder already turns `version` + `commit` into
# `-X main.version` / `-X main.commit` ldflags. This pins the newer
# behavior: when the build's module dir carries a `version.env`
# (eng-versioning(7) convention — one `export <PACKAGE>_VERSION=<sem>`
# line per package), the builder reads it at eval time and uses it as
# the version source of truth for BOTH the derivation `version` attr and
# the `-X main.version` ldflag, so consumers stop repeating the
# readFile/match boilerplate in their flake.
#
# Precedence pinned here: explicit `version` > version.env > "dev".
# These are eval-time assertions on `drv.version` / `drv.ldflags`; no Go
# toolchain runs.
{
  pkgs ? import ../../.. { },
}:
let
  # Minimal single-module fixture, optionally carrying a version.env.
  mkFixture =
    name: extra:
    pkgs.runCommand name { } ''
      mkdir -p $out
      echo "module example.com/x" > $out/go.mod
      echo "go 1.26" >> $out/go.mod
      touch $out/go.sum
      touch $out/gomod2nix.toml
      ${extra}
    '';

  # `export FOO_VERSION=...` — the purse-first form (export prefix).
  withExportEnv = mkFixture "ve-export" ''
    echo "export FOO_VERSION=1.2.3" > $out/version.env
  '';
  # `BAR_VERSION=...` — the madder form (bare, no export).
  withBareEnv = mkFixture "ve-bare" ''
    echo "BAR_VERSION=9.9.9" > $out/version.env
  '';
  # version.env present but with no `*_VERSION=` line → must fall back.
  withNoVersionLine = mkFixture "ve-noline" ''
    echo "# nothing to see here" > $out/version.env
  '';
  # No version.env at all → must fall back.
  withoutEnv = mkFixture "ve-none" "";

  build =
    src: extra:
    pkgs.buildGoApplication (
      {
        inherit src;
        pwd = src;
        pname = "smoke";
      }
      // extra
    );

  exportDrv = build withExportEnv { };
  bareDrv = build withBareEnv { };
  explicitWinsDrv = build withExportEnv { version = "0.0.0-explicit"; };
  noLineDrv = build withNoVersionLine { };
  noEnvDrv = build withoutEnv { };

  hasLdflag = drv: flag: builtins.elem flag drv.ldflags;

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "version-env-tests" {
  _ignored = [
    # version.env with `export` prefix → drives version attr + ldflag.
    (assert' "export form: derivation version attr from version.env" (exportDrv.version == "1.2.3"))
    (assert' "export form: -X main.version ldflag from version.env" (
      hasLdflag exportDrv "-X main.version=1.2.3"
    ))

    # version.env without `export` (bare) → parsed identically.
    (assert' "bare form: derivation version attr from version.env" (bareDrv.version == "9.9.9"))
    (assert' "bare form: -X main.version ldflag from version.env" (
      hasLdflag bareDrv "-X main.version=9.9.9"
    ))

    # Explicit `version` wins over version.env (backward compatible).
    (assert' "explicit version wins (attr)" (explicitWinsDrv.version == "0.0.0-explicit"))
    (assert' "explicit version wins (ldflag)" (
      hasLdflag explicitWinsDrv "-X main.version=0.0.0-explicit"
    ))

    # version.env present but no `*_VERSION=` line → graceful fallback.
    (assert' "no _VERSION line falls back to dev ldflag" (hasLdflag noLineDrv "-X main.version=dev"))

    # No version.env → unchanged fallback behavior.
    (assert' "no version.env falls back to dev ldflag" (hasLdflag noEnvDrv "-X main.version=dev"))
  ];
} "touch $out"
