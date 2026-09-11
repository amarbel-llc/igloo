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
  meta = {
    description = "Per-package Go lint suite for buildGodynLint (unitchecker protocol)";
    mainProgram = "godyn-lint";
  };
}
