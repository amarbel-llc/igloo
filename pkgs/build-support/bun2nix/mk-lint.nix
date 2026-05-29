# Shared lint-derivation factory: runs the vendored eslint stack
# against a source tree's entrypoints. Keyed only on
# (src, eslintCache, entrypointPaths) so it doesn't re-run when
# unrelated bundle inputs (bunBuildFlags, bunfigPath, etc.) change.
#
# Consumed by buildBunBinary and buildZxScript via mkBundle's
# `buildInputs = lib.optional runLint lintResult` — lint failures
# propagate to the bundle through the dependency edge without being
# re-evaluated.
{ pkgs, lib }:

{
  pname,
  version ? "0.0.0",
  src,
  eslintCache,
  entrypointPaths,
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "${pname}-lint";
  inherit version src;
  nativeBuildInputs = [ eslintCache ];

  buildPhase = ''
    runHook preBuild
    eslint ${lib.escapeShellArgs entrypointPaths}
    runHook postBuild
  '';

  installPhase = "touch $out";
  dontFixup = true;
}
