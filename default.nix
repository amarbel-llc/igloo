# Compatibility shim for consumers that do `import nixpkgs { ... }`
# rather than `nixpkgs.legacyPackages.${system}`.
#
# Resolves the upstream nixpkgs revision from flake.lock and forwards.
# Auto-applies the fork's overlay so that `buildGoApplication`,
# `fetchGgufModel`, the bun2nix builders, and pins are present on the
# returned pkgs set — matching the behavior of the previous full-fork
# repo where these attributes were baked into pkgs/top-level/all-packages.nix.
#
# Consumers may pass extra overlays via `overlays = [ ... ]`; they are
# composed AFTER the fork's overlay so they can override pins.
{
  system ? builtins.currentSystem,
  overlays ? [ ],
  config ? { },
  ...
}@args:
let
  flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
  nixpkgsLock = flakeLock.nodes."nixpkgs-master".locked;
  nixpkgsSrc = builtins.fetchTree {
    type = "github";
    owner = nixpkgsLock.owner;
    repo = nixpkgsLock.repo;
    rev = nixpkgsLock.rev;
    inherit (nixpkgsLock) narHash;
  };
  lib = import "${nixpkgsSrc}/lib";
  forkOverlay = lib.composeManyExtensions (import ./overlays lib);
in
import nixpkgsSrc (
  args
  // {
    inherit system;
    overlays = [ forkOverlay ] ++ overlays;
    config = config // {
      allowUnfree = config.allowUnfree or true;
    };
  }
)
