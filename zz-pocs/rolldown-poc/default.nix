{ mkBunDerivation, fetchBunDeps }:

mkBunDerivation {
  src = ./.;
  packageJson = ./package.json;
  bunDeps = fetchBunDeps {
    bunNix = ./bun.nix;
  };

  # Override: run the package.json `build` script (which invokes rolldown)
  # instead of `bun build` (Bun's own bundler) that the hook defaults to.
  # BROWSER_TYPE is read by rolldown.config.mjs to name the output dir.
  buildPhase = ''
    runHook preBuild
    BROWSER_TYPE=chrome bun run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r dist-chrome "$out/"
    runHook postInstall
  '';
}
