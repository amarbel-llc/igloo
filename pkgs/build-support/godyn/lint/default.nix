# godyn-lint — buildGodynLint's analyzer suite (vet passes + staticcheck defaults,
# //nolint suppression) as a unitchecker binary. Its gomod2nix.toml is refreshed
# with `just explore-update-godyn-lint-deps`.
{ buildGoApplication, go }:
buildGoApplication {
  pname = "godyn-lint";
  version = "0.1.0";
  src = ./.;
  modules = ./gomod2nix.toml;
  inherit go;
  CGO_ENABLED = "0";
  GOTOOLCHAIN = "local";
  # Built against x/tools >= v0.50: its unitchecker reads each import's TYPES from
  # that import's vetx file (not PackageFile), so the lanes must supply a vetx for
  # every import, stdlib included (igloo#71).
  passthru.typedVetx = true;
  meta = {
    description = "Per-package Go lint suite for buildGodynLint (unitchecker protocol)";
    mainProgram = "godyn-lint";
  };
}
