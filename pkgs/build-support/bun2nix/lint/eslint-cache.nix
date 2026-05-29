# Materialize the vendored eslint stack into a content-addressed store
# path that exposes a single `bin/eslint` already wired to the bundled
# flat config. Built once per (eslint, plugin, parser) version triple —
# bumps go through `nix run .#regen-bun2nix-lint-stack` (see regen.nix), which
# updates bun.lock and bun.nix; the cache rebuilds automatically.
{
  pkgs,
  bun,
  fetchBunDeps,
  bunNix,
  packageJson,
  bunLock,
  eslintConfig,
}:

let
  cache = fetchBunDeps { inherit bunNix; };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "bun-fork-lint";
  version = "0.0.1";
  dontUnpack = true;

  nativeBuildInputs = [
    bun
    pkgs.makeWrapper
  ];

  buildPhase = ''
    runHook preBuild

    cp ${packageJson} package.json
    cp ${bunLock} bun.lock
    cp ${eslintConfig} eslint.config.js

    export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
    cp -r ${cache}/share/bun-cache/. "$BUN_INSTALL_CACHE_DIR"
    bun install --frozen-lockfile --linker=isolated

    mkdir -p $out/bin
    mv node_modules $out/node_modules
    mv eslint.config.js $out/eslint.config.js

    makeWrapper $out/node_modules/.bin/eslint $out/bin/eslint \
      --add-flags "--config $out/eslint.config.js --no-config-lookup"

    runHook postBuild
  '';

  dontInstall = true;
  dontFixup = true;
}
