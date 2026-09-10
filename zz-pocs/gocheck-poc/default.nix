# POC driver for FDR 0006 / amarbel-llc/igloo#62: prove that buildGoLint
# resolves a bridged-ONLY package hermetically and offline.
#
# The consumer imports example.com/producer/newpkg. Its go.mod requires
# example.com/producer v1.0.0 — a fictional version that has no newpkg and is
# unreachable via any proxy — and bridges the module via goFlakeInputs to the
# local ./producer source (which HAS newpkg). So resolving producer/newpkg is
# possible ONLY through the bridge: exactly the mesa-in-newer-dewey shape.
#
# Build:
#   nix-build zz-pocs/gocheck-poc -A lint       # PASS: green (bridge resolves)
#   nix-build zz-pocs/gocheck-poc -A control    # FAIL: no bridge -> can't load
#
# (git add -N the fixture files first; nix path-imports under a git worktree
# reject untracked paths.)
{
  pkgs ? import ../.. { },
}:
let
  mkBase =
    { pname, goFlakeInputs }:
    pkgs.buildGoApplication {
      inherit pname goFlakeInputs;
      # The synthetic consumer's gomod2nix.toml carries no goPackagePath, so
      # buildGoApplication derives no version — supply one so mkDerivation has
      # a name.
      version = "0.1.0";
      src = ./consumer;
      pwd = ./consumer;
      modules = ./consumer/gomod2nix.toml;
      subPackages = [ "." ];
      # The lint lane replaces the build; the base's own binary build/test is
      # irrelevant here (and the control base would fail it anyway).
      doCheck = false;
    };

  # Bridged: producer/newpkg resolves through the goFlakeInputs replace.
  bridgedBase = mkBase {
    pname = "gocheck-poc-bridged";
    goFlakeInputs = {
      "example.com/producer" = ./producer;
    };
  };

  # Control: identical consumer, NO bridge. producer v1.0.0 (hence newpkg) is
  # unreachable, so golangci-lint's package load fails — proving the bridge is
  # what makes `lint` pass.
  unbridgedBase = mkBase {
    pname = "gocheck-poc-unbridged";
    goFlakeInputs = { };
  };
in
{
  # Phase 2 (core proof). Green == golangci-lint resolved the bridged-only
  # package inside the sandbox, offline.
  lint = pkgs.buildGoLint {
    base = bridgedBase;
    golangci-lint = pkgs.golangci-lint;
  };

  # Warm-cache lane (spinclass#294): same lint, seeded from mkGoLintCacheEnv.
  # Off Linux builders the seed is dropped (cacheSeed == null) and it runs cold.
  lintWarm = pkgs.buildGoLint {
    base = bridgedBase;
    golangci-lint = pkgs.golangci-lint;
    warmCache = true;
  };

  # Phase 3 (control). EXPECTED to fail its build with a go/packages load
  # error (`no required module provides package example.com/producer/newpkg`).
  control = pkgs.buildGoLint {
    base = unbridgedBase;
    golangci-lint = pkgs.golangci-lint;
  };
}
