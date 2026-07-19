/**
  bun2nix build-support library.

  Exposes helpers for packaging Bun (JavaScript/TypeScript runtime) projects
  as Nix derivations. The public surface is:

  - `buildBunBinary` / `buildBunBinaries` — compile + wrap a TypeScript project
  - `buildZxScript` / `buildZxScriptFromFile` — package a zx shell script
  - `fetchBunDeps` — pre-fetch npm dependencies from a `bun.nix` lockfile
  - `mkBunDerivation` — `stdenv.mkDerivation` with Bun conventions
  - `writeBunApplication` — install a Bun server/app with a launcher wrapper
  - `writeBunScriptBin` — write a plain Bun shebang script

  All helpers that fetch npm packages require `cacheEntryCreator`, a Zig
  binary from the `nix-community/bun2nix` flake
  (`packages.\${system}.cacheEntryCreator`). It is not vendored here; callers
  must provide it. The default argument throws an informative error.

  The `bun` argument defaults to `pkgs.bun` and can be overridden to use a
  trimmed runtime once one is available.
*/

{
  pkgs,
  lib ? pkgs.lib,
  bun ? pkgs.bun,
  cacheEntryCreator ? throw "bun2nix: cacheEntryCreator must be provided — pass packages.cacheEntryCreator from the nix-community/bun2nix flake",
  # Lint stack override. Omit to use the vendored stack at ./lint/.
  # Pass a custom derivation to override. Pass null to disable lint
  # globally — every buildBunBinary / buildZxScript call then behaves
  # as if `disableLint = true`. The default must build inside the let
  # block (it depends on `fetchBunDeps`), so it's resolved below via
  # `args.eslintCache or defaultEslintCache`.
  ...
}@args:

let
  # -- leaf components (no internal deps) --

  bun2nixNoOp = import ./bun2nix-no-op.nix { inherit pkgs; };

  extractPackage = import ./fetch-bun-deps/extract-package.nix { inherit pkgs lib; };

  # -- mid-level components --

  overridePackage = import ./fetch-bun-deps/override-package.nix { inherit pkgs lib extractPackage; };

  patchedDependenciesToOverrides = import ./fetch-bun-deps/patched-dependencies-to-overrides.nix {
    inherit pkgs lib;
  };

  buildPackage = import ./fetch-bun-deps/build-package.nix {
    inherit
      pkgs
      lib
      bun
      extractPackage
      cacheEntryCreator
      ;
  };

  # -- top-level components --

  fetchBunDeps = import ./fetch-bun-deps.nix {
    inherit
      pkgs
      lib
      buildPackage
      overridePackage
      patchedDependenciesToOverrides
      ;
  };

  hook = import ./hook.nix {
    inherit
      pkgs
      lib
      bun
      bun2nixNoOp
      ;
  };

  mkDerivation = import ./mk-derivation.nix { inherit pkgs lib hook; };

  writeBunApplication = import ./write-bun-application.nix {
    inherit
      pkgs
      lib
      bun
      mkDerivation
      ;
  };

  writeBunScriptBin = import ./write-bun-script-bin.nix { inherit pkgs bun; };

  mkWrapper = import ./mk-wrapper.nix { inherit pkgs lib bun; };

  mkLint = import ./mk-lint.nix { inherit pkgs lib; };

  # Lint stack: materialized once per (eslint, plugin, parser) version
  # triple and reused by every buildBunBinary / buildZxScript bundle.
  # Bumps go through `nix run .#regen-bun2nix-lint-stack` at the flake
  # level. Callers can pass `eslintCache = null` to disable lint
  # globally; per-call opt-out is `disableLint = true`.
  defaultEslintCache = import ./lint/eslint-cache.nix {
    inherit pkgs bun fetchBunDeps;
    bunNix = ./lint/bun.nix;
    packageJson = ./lint/package.json;
    bunLock = ./lint/bun.lock;
    eslintConfig = ./lint/eslint.config.js;
  };
  eslintCache = args.eslintCache or defaultEslintCache;

  bunBinaryBuilders = import ./build-bun-binary.nix {
    inherit
      pkgs
      lib
      bun
      fetchBunDeps
      eslintCache
      mkWrapper
      mkLint
      ;
  };

  zxScriptBuilder = import ./build-zx-script.nix {
    inherit
      pkgs
      lib
      bun
      fetchBunDeps
      eslintCache
      mkWrapper
      mkLint
      ;
  };

in
{
  inherit (bunBinaryBuilders) buildBunBinary buildBunBinaries;
  inherit (zxScriptBuilder) buildZxScript buildZxScriptFromFile;
  inherit
    eslintCache
    fetchBunDeps
    hook
    writeBunApplication
    writeBunScriptBin
    ;
  mkBunDerivation = mkDerivation;
}
