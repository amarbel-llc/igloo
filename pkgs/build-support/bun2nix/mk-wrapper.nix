# Shared wrapper-script factory used by buildBunBinary and buildZxScript.
# Produces $out/bin/<name>: a shell wrapper that execs bun on a pre-built
# ESM bundle. The bundle (and lint, when present) are exposed via
# passthru so callers (e.g. pkgs.testers.testBuildFailure') can target
# the underlying derivations directly — failures inside those
# derivations propagate as build-input failures to the wrapper, which
# testBuildFailure cannot catch.
#
# LD_LIBRARY_PATH is unset so devshell library leaks don't bleed into
# the script's runtime environment. See amarbel-llc/bun#4.
{
  pkgs,
  lib,
  bun,
}:

{
  name,
  bundle,
  jsFile,
  lint ? null,
  runtimeInputs ? [ ],
  runtimeEnv ? { },
}:
let
  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") runtimeEnv
  );
  pathSetup = lib.optionalString (runtimeInputs != [ ]) ''
    export PATH="${lib.makeBinPath runtimeInputs}:$PATH"
  '';
  wrapper = pkgs.writeShellScriptBin name ''
    ${envExports}
    ${pathSetup}
    unset LD_LIBRARY_PATH
    exec ${bun}/bin/bun ${bundle}/${jsFile} "$@"
  '';
in
wrapper
// {
  passthru =
    (wrapper.passthru or { })
    // {
      inherit bundle;
    }
    // lib.optionalAttrs (lint != null) { inherit lint; };
}
