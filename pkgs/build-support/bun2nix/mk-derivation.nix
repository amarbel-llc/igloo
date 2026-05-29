/**
  `stdenv.mkDerivation` extended with Bun-specific build conventions.

  Wraps `stdenv.mkDerivation` via `lib.extendMkDerivation`. The setup hook
  (`bun2nix-hook`) is automatically added to `nativeBuildInputs`. Build flags
  default to a compile+minify+sourcemap invocation derived from the
  `module` field in `packageJson` when no explicit `bunBuildFlags` is given.

  For custom build phases, use `hook` directly with a plain
  `stdenv.mkDerivation`. `mkBunDerivation` is the higher-level convenience
  wrapper for standard compile builds.

  # Inputs

  `bunDeps`
  : Output of `fetchBunDeps`. Required unless `packageJson` is set (in which
    case the derivation only runs `bun install` without a lockfile check).

  `packageJson` (optional)
  : Path to `package.json`. When provided, `pname` and `version` default to
    the `name` and `version` fields in the file.

  `pname` (optional if `packageJson` is set)
  : Package name. Takes priority over `packageJson.name`.

  `version` (optional if `packageJson` is set)
  : Package version. Takes priority over `packageJson.version`.

  `bunBuildFlags` (optional)
  : Explicit flags for `bun build`. When omitted and `packageJson.module`
    is present, defaults to `[module --outfile pname --compile --minify
    --sourcemap]` (plus `--bytecode` if `bunCompileToBytecode` is true).

  `bunCompileToBytecode` (optional, default `true`)
  : Append `--bytecode` to the default build flags.

  `extraBunBuildFlags` (optional)
  : Flags appended to the default build flags before `removeBunBuildFlags`.

  `removeBunBuildFlags` (optional)
  : Flags to remove from the default build flags list.

  `dontFixup` (optional)
  : Defaults to `true` when `buildPhase` is not set, because Bun binaries
    are broken by the default fixup phase.

  # Type

  ```
  mkBunDerivation :: AttrSet -> Derivation
  ```

  # Examples
  :::{.example}
  ## `mkBunDerivation` usage example

  ```nix
  mkBunDerivation {
    pname = "my-app";
    version = "1.0.0";
    src = ./.;
    packageJson = ./package.json;
    bunDeps = fetchBunDeps { bunNix = ./bun.nix; };
  }
  ```

  :::
*/
{ pkgs, lib, hook }:

lib.extendMkDerivation {
  constructDrv = pkgs.stdenv.mkDerivation;

  extendDrvArgs =
    _finalAttrs:
    {
      packageJson ? null,
      dontPatchShebangs ? false,
      nativeBuildInputs ? [ ],
      # Bun binaries built by this derivation become broken by the default fixupPhase
      dontFixup ? !(args ? buildPhase),
      bunCompileToBytecode ? true,
      removeBunBuildFlags ? [ ],
      extraBunBuildFlags ? [ ],
      ...
    }@args:

    assert lib.assertMsg (!(args ? bunNix)) ''
      bun2nix.mkDerivation: `bunNix` cannot be passed to `bun2nix.mkDerivation` directly.
      It should be wrapped in `bun2nix.fetchBunDeps` like follows:

      # Example
      ```nix
      bunDeps = bun2nix.fetchBunDeps {
        bunNix = ./bun.nix;
      };
      ```
    '';

    assert lib.assertMsg (args ? bunDeps || packageJson != null) ''
      Please set `bunDeps` in order to use `bun2nix.mkDerivation`
      to build your package.

      # Example
      ```nix
      stdenv.mkDerivation {
        <other inputs>

        nativeBuildInputs = [
          bun2nix.hook
        ];

        bunDeps = bun2nix.fetchBunDeps {
          bunNix = ./bun.nix;
        };
      }
    '';

    assert lib.assertMsg (args ? pname || packageJson != null)
      "bun2nix.mkDerivation: Either `pname` or `packageJson` must be set in order to assign a name to the package. It may be assigned manually with `pname` which always takes priority or read from the `name` field of `packageJson`.";

    assert lib.assertMsg (args ? version || packageJson != null)
      "bun2nix.mkDerivation: Either `version` or `packageJson` must be set in order to assign a version to the package. It may be assigned manually with `version` which always takes priority or read from the `version` field of `packageJson`.";

    let
      pkgJsonContents = builtins.readFile packageJson;
      package = if packageJson != null then (builtins.fromJSON pkgJsonContents) else { };

      pname = args.pname or package.name or null;
      version = args.version or package.version or null;
      module = args.module or package.module or null;
    in

    assert lib.assertMsg (pname != null) ''
      bun2nix.mkDerivation: Either `name` must be specified in the given `packageJson` file, or passed as the `name` argument.

      `package.json`:
      ```json
      ${pkgJsonContents}
      ```
    '';

    assert lib.assertMsg (version != null) ''
      bun2nix.mkDerivation: Either `version` must be specified in the given `packageJson` file, or passed as the `version` argument.

      `package.json`:
      ```json
      ${pkgJsonContents}
      ```
    '';
    {
      inherit
        pname
        version
        dontFixup
        dontPatchShebangs
        ;

      inherit (args) bunDeps;

      bunBuildFlags =
        if (args ? bunBuildFlags) then
          args.bunBuildFlags
        else if module == null then
          [ ]
        else
          let
            defaultBuildFlags = [
              "${module}"
              "--outfile"
              "${pname}"
              "--compile"
              "--minify"
              "--sourcemap"
            ]
            ++ extraBunBuildFlags
            ++ lib.optional bunCompileToBytecode "--bytecode";
          in
          lib.lists.subtractLists removeBunBuildFlags defaultBuildFlags;

      meta.mainProgram = pname;

      nativeBuildInputs = nativeBuildInputs ++ [
        hook
      ];
    };
}
