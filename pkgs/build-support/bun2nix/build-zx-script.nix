/**
  Package a [zx](https://github.com/google/zx) TypeScript script as a
  Nix derivation. Four usage tiers with increasing dependency complexity.

  `buildZxScript` — builds from a source tree (tiers 1–3).
  `buildZxScriptFromFile` — builds from a single `.ts` file with inline
  `///!dep` directives (tier 4).

  The generated wrapper unsets `LD_LIBRARY_PATH` to prevent devshell
  library leaks from bleeding into the script's runtime environment.

  # Inputs

  `pname`
  : Package name; becomes the binary name.

  `version` (optional, default `"0.0.0"`)
  : Package version string.

  `src` (for `buildZxScript`)
  : Source tree. For tiers 1–2 only the entrypoint file is needed.
    For tier 3 the tree must contain `bun.lock`.

  `script` (for `buildZxScriptFromFile`)
  : Path to a single `.ts` file. Dependencies are declared inline as
    `///!dep name@version sha512-<hash>` directives.

  `entrypoint` (optional, default `"index.ts"`)
  : Source-relative path to the entry file within `src`. (`buildZxScript` only.)

  `bunNix` (optional)
  : Path to a `bun.nix` lockfile (tier 3). When set, `src` must contain
    `bun.lock` and `extraDeps` is ignored.

  `extraDeps` (optional)
  : Attrset of `{ "name@version" = fetchurl { ... }; }` for packages with no
    transitive dependencies (tier 2).

  `bunBuildFlags` (optional)
  : Extra flags forwarded to `bun build`.

  `runtimeInputs` (optional)
  : Packages added to `PATH` in the wrapper script at runtime.

  `runtimeEnv` (optional)
  : Attrset of environment variables exported by the wrapper script.

  `bunfigPath` (optional)
  : Path to `bunfig.toml` for private registry credentials.

  `npmrcPath` (optional)
  : Path to `.npmrc` for private registry credentials.

  `overrides` (optional)
  : Source overrides forwarded to `fetchBunDeps` (tier 3 only).

  `disableLint` (optional, default `false`)
  : Skip the eslint pass for this call. Same semantics as
    `buildBunBinary`'s `disableLint`.

  # Type

  ```
  buildZxScript         :: AttrSet -> Derivation
  buildZxScriptFromFile :: AttrSet -> Derivation
  ```

  # Examples
  :::{.example}
  ## Tier 1 — zero-config (zx only)

  ```nix
  buildZxScript {
    pname = "my-tool";
    src = ./.;
  }
  ```

  :::
  :::{.example}
  ## Tier 4 — inline deps via `///!dep` directives

  ```typescript
  ///!dep zx@8.8.5 sha512-SNgDF5L0gfN7FwVOdEFguY3orU5AkfFZm9B5YSHog/...
  import { $ } from "zx";
  await $`echo hello`;
  ```

  ```nix
  buildZxScriptFromFile {
    pname = "my-tool";
    script = ./my-tool.ts;
  }
  ```

  :::
*/
{
  pkgs,
  lib,
  bun,
  fetchBunDeps,
  eslintCache,
  mkWrapper,
  mkLint,
}:

let
  # -- Helpers --

  # Map a .ts/.tsx/.mts/.cts basename to .js
  tsToJs =
    name:
    lib.replaceStrings [ ".ts" ".tsx" ".mts" ".cts" ] [ ".js" ".js" ".js" ".js" ] (
      builtins.baseNameOf name
    );

  # Parse "name@version" into { name, version }.
  parseDepKey =
    key:
    let
      # Split on last @ (handles scoped packages like @scope/pkg@1.0.0)
      parts = lib.splitString "@" key;
      len = builtins.length parts;
      # For "@scope/pkg@1.0.0" → ["" "scope/pkg" "1.0.0"]
      # For "pkg@1.0.0" → ["pkg" "1.0.0"]
      name = if len == 3 then "@${builtins.elemAt parts 1}" else builtins.elemAt parts 0;
      version = builtins.elemAt parts (len - 1);
    in
    {
      inherit name version;
    };

  # Construct the npm registry tarball URL for a "name@version" key.
  mkTarballUrl =
    key:
    let
      parsed = parseDepKey key;
      bareName =
        if lib.hasPrefix "@" parsed.name then
          builtins.elemAt (lib.splitString "/" parsed.name) 1
        else
          parsed.name;
    in
    "https://registry.npmjs.org/${parsed.name}/-/${bareName}-${parsed.version}.tgz";

  # -- Vendored zx dependency --
  # Bump: update zxVersion and zxHash together.
  zxVersion = "8.8.5";
  zxHash = "sha512-SNgDF5L0gfN7FwVOdEFguY3orU5AkfFZm9B5YSHog/UDHv+lvmd82ZAsOenOkQixigwH2+yyH198AwNdKhj+RA==";
  zxDep = {
    "zx@${zxVersion}" = pkgs.fetchurl {
      url = mkTarballUrl "zx@${zxVersion}";
      hash = zxHash;
    };
  };

  # -- Eval-time directive parsers (for buildZxScriptFromFile) --

  # Extract ///!dep directives from script content.
  # Returns a list of { key, hash } attrsets.
  # Throws at eval time if any directive is missing its SRI hash.
  parseDepLines =
    scriptPath: content:
    let
      lines = builtins.filter builtins.isString (builtins.split "\n" content);
      parseLine =
        line:
        let
          depWithHash = builtins.match "^///!dep[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+).*" line;
          depWithoutHash = builtins.match "^///!dep[[:space:]]+([^[:space:]]+)[[:space:]]*$" line;
        in
        if depWithHash != null then
          {
            key = builtins.elemAt depWithHash 0;
            hash = builtins.elemAt depWithHash 1;
          }
        else if depWithoutHash != null then
          builtins.throw ''
            buildZxScriptFromFile: ///!dep ${builtins.elemAt depWithoutHash 0} has no SRI hash.

            Run: bun scripts/update-zx-deps.ts ${builtins.toString scriptPath}
          ''
        else
          null;
    in
    builtins.filter (x: x != null) (builtins.map parseLine lines);

  # Generate synthetic package.json content from a dep attrset.
  mkPackageJson =
    pname: allDeps:
    let
      deps = lib.mapAttrs' (
        key: _:
        let
          parsed = parseDepKey key;
        in
        lib.nameValuePair parsed.name parsed.version
      ) allDeps;
    in
    builtins.toJSON {
      name = pname;
      dependencies = deps;
    };

  # Generate synthetic bun.lock content from a dep attrset.
  # Each dep becomes a lockfile package tuple:
  #   [resolved_spec, "", {}, integrity_hash]
  mkBunLock =
    pname: allDeps:
    let
      deps = lib.mapAttrs' (
        key: _:
        let
          parsed = parseDepKey key;
        in
        lib.nameValuePair parsed.name parsed.version
      ) allDeps;

      packages = lib.mapAttrs' (
        key: dep:
        let
          parsed = parseDepKey key;
        in
        lib.nameValuePair parsed.name [
          key
          ""
          { }
          dep.outputHash
        ]
      ) allDeps;
    in
    builtins.toJSON {
      lockfileVersion = 1;
      workspaces = {
        "" = {
          name = pname;
          dependencies = deps;
        };
      };
      inherit packages;
    };

  buildZxScript =
    {
      pname,
      version ? "0.0.0",
      src,
      entrypoint ? "index.ts",
      bunNix ? null,
      bunBuildFlags ? [ ],
      runtimeInputs ? [ ],
      runtimeEnv ? { },
      extraDeps ? { },
      bunfigPath ? null,
      npmrcPath ? null,
      overrides ? { },
      disableLint ? false,
      _skipBuiltinZx ? false,
      ...
    }:
    let
      # Tier 3: full override via bunNix
      useBunNix = bunNix != null;
      runLint = !disableLint && eslintCache != null;

      # Tiers 1 & 2: merge vendored zx with extraDeps
      # When _skipBuiltinZx is true (used by buildZxScriptFromFile), the
      # caller provides the zx dep via extraDeps from the script directives.
      allDeps = (if _skipBuiltinZx then { } else zxDep) // extraDeps;

      # -- Cache --
      # Tier 3: use fetchBunDeps (same as buildBunBinary)
      # Tiers 1&2: symlinkJoin of fetchurl tarballs
      cache = fetchBunDeps {
        bunNix =
          if useBunNix then
            bunNix
          else
            # Programmatic bunNix: ignore injected fetchurl, return
            # pre-fetched tarballs directly.
            { ... }:
            allDeps;
        inherit bunfigPath npmrcPath overrides;
      };

      # -- Synthetic files (tiers 1 & 2 only) --
      syntheticPackageJson = pkgs.writeText "${pname}-package.json" (mkPackageJson pname allDeps);
      syntheticBunLock = pkgs.writeText "${pname}-bun.lock" (mkBunLock pname allDeps);

      # -- Lint (when enabled) -- separate derivation keyed only on
      # (src, eslintCache, entrypointPaths) so it doesn't re-run when
      # unrelated bundle inputs change. Failures propagate to the
      # bundle via buildInputs.
      lint = mkLint {
        inherit
          pname
          version
          src
          eslintCache
          ;
        entrypointPaths = [ entrypoint ];
      };

      # -- Bundle derivation --
      bundle = pkgs.stdenvNoCC.mkDerivation {
        pname = "${pname}-bundle";
        inherit version src;

        nativeBuildInputs = [ bun ];
        buildInputs = lib.optional runLint lint;

        buildPhase = ''
          runHook preBuild

          export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
        ''
        + ''
          cp -r ${cache}/share/bun-cache/. "$BUN_INSTALL_CACHE_DIR"
        ''
        + (
          if useBunNix then
            # Tier 3: src contains bun.lock
            ''
              bun install --frozen-lockfile --linker=isolated
            ''
          else
            # Tiers 1&2: inject synthetic package.json + bun.lock
            ''
              cp ${syntheticPackageJson} package.json
              cp ${syntheticBunLock} bun.lock
              bun install --frozen-lockfile --linker=isolated
            ''
        )
        + ''
          mkdir -p $out
          bun build ${lib.escapeShellArg entrypoint} \
            --target=bun \
            --format=esm \
            --outdir=$out \
            ${lib.escapeShellArgs bunBuildFlags}

          runHook postBuild
        '';

        dontInstall = true;
        dontFixup = true;

        passthru = lib.optionalAttrs runLint { inherit lint; };
      };
    in
    mkWrapper {
      name = pname;
      inherit bundle runtimeInputs runtimeEnv;
      jsFile = tsToJs entrypoint;
      lint = bundle.passthru.lint or null;
    };

  # Tier 4: file-based deps — deps declared inline via ///!dep directives.
  #
  # Usage:
  #   buildZxScriptFromFile {
  #     pname = "my-tool";
  #     script = ./my-tool.ts;
  #   }
  #
  # The script must contain ///!dep directives with SRI hashes:
  #   ///!dep zx@8.8.5 sha512-SNgDF5L0gfN7FwVOd...
  #   ///!dep chalk@5.4.1 sha512-zgVZuo2WcZgfUEm...
  #
  # Use `bun scripts/update-zx-deps.ts <script>` to resolve hashes.
  buildZxScriptFromFile =
    {
      pname,
      version ? "0.0.0",
      script,
      bunBuildFlags ? [ ],
      runtimeInputs ? [ ],
      runtimeEnv ? { },
      disableLint ? false,
      ...
    }:
    let
      content = builtins.readFile script;
      deps = parseDepLines script content;

      extraDeps = builtins.listToAttrs (
        builtins.map (dep: {
          name = dep.key;
          value = pkgs.fetchurl {
            url = mkTarballUrl dep.key;
            hash = dep.hash;
          };
        }) deps
      );

      entrypoint = builtins.baseNameOf (builtins.toString script);

      srcDir = pkgs.runCommandLocal "${pname}-src" { } ''
        mkdir -p $out
        cp ${script} $out/${entrypoint}
      '';
    in
    buildZxScript {
      inherit
        pname
        version
        bunBuildFlags
        runtimeInputs
        runtimeEnv
        extraDeps
        entrypoint
        disableLint
        ;
      src = srcDir;
      _skipBuiltinZx = true;
    };

in
{
  inherit buildZxScript buildZxScriptFromFile;
}
