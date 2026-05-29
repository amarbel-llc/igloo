/**
  gomod2nix CLI tool.

  Generates `gomod2nix.toml` lockfiles from a Go module's `go.mod`.
  Used by `buildGoApplication`'s `passthru.updateScript` and by devshell
  hooks (`go-sync-wrap.sh`) to keep `gomod2nix.toml` in sync after
  `go get` / `go mod tidy`.

  Built with `buildGoApplication` using its own vendored `gomod2nix.toml`,
  so there is no circular dependency: the lockfile is pre-generated and
  checked in alongside the source.
*/
{ buildGoApplication, go }:

buildGoApplication {
  pname = "gomod2nix";
  version = "1.0.0";
  src = ./.;
  modules = ./gomod2nix.toml;
  inherit go;
  CGO_ENABLED = "0";
  GOTOOLCHAIN = "local";
}
