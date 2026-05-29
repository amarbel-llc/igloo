/**
  Build a Bun web application or server as a runnable Nix package.

  Extends `mkBunDerivation` with an install phase that copies the project
  tree to `$out/share/$pname` and creates a `$out/bin/$pname` launcher
  via `makeWrapper`. The launcher runs `startScript` with `bun` on PATH,
  chdir'd into the installed share directory.

  Use this for projects where the deliverable is a running process
  (e.g. an HTTP server) rather than a compiled binary. For compiled
  binaries, use `buildBunBinary` instead.

  # Inputs

  `startScript`
  : Shell script body (passed to `writeShellApplication`) that starts the
    application, e.g. `"bun run start"`.

  `runtimeInputs` (optional)
  : Extra packages available on `PATH` inside `startScript`.

  `runtimeEnv` (optional)
  : Attrset of environment variables set in the launcher script.

  `excludeShellChecks` (optional)
  : `shellcheck` codes to suppress (forwarded to `writeShellApplication`).

  `extraShellCheckFlags` (optional)
  : Extra flags for shellcheck.

  `bashOptions` (optional, default `["errexit" "nounset" "pipefail"]`)
  : Bash options for the launcher script.

  `inheritPath` (optional, default `true`)
  : Whether the launcher inherits the caller's `PATH`.

  All other arguments are forwarded to `mkBunDerivation`.

  # Type

  ```
  writeBunApplication :: AttrSet -> Derivation
  ```

  # Examples
  :::{.example}
  ## `writeBunApplication` usage example

  ```nix
  writeBunApplication {
    pname = "my-server";
    version = "1.0.0";
    src = ./.;
    packageJson = ./package.json;
    bunDeps = fetchBunDeps { bunNix = ./bun.nix; };
    startScript = "bun run start";
  }
  ```

  :::
*/
{ pkgs, lib, bun, mkDerivation }:

lib.extendMkDerivation {
  constructDrv = mkDerivation;

  excludeDrvArgNames = [
    "startScript"
    "runtimeInputs"
    "runtimeEnv"
    "excludeShellChecks"
    "extraShellCheckFlags"
    "bashOptions"
    "inheritPath"
  ];

  extendDrvArgs =
    _finalAttrs:
    {
      startScript,
      runtimeInputs ? [ ],
      runtimeEnv ? { },
      excludeShellChecks ? [ ],
      extraShellCheckFlags ? [ ],
      bashOptions ? [
        "errexit"
        "nounset"
        "pipefail"
      ],
      inheritPath ? true,
      nativeBuildInputs ? [ ],
      ...
    }@args:
    let
      script = pkgs.writeShellApplication {
        inherit
          runtimeEnv
          excludeShellChecks
          extraShellCheckFlags
          bashOptions
          inheritPath
          ;

        name = "bun2nix-application-startup";
        text = startScript;
        runtimeInputs = [
          bun
        ]
        ++ runtimeInputs;
      };
    in
    {
      nativeBuildInputs = [
        pkgs.makeWrapper
      ]
      ++ nativeBuildInputs;

      installPhase =
        args.installPhase or ''
          runHook preInstall

          mkdir -p \
            "$out/share/$pname" \
            "$out/bin"

          cp -r ./. "$out/share/$pname"

          makeWrapper ${lib.getExe script} $out/bin/$pname \
            --chdir "$out/share/$pname"

          runHook postInstall
        '';
    };
}
