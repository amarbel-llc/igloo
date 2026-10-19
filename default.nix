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
#
# `nixpkgs` (optional) selects the nixpkgs source tree to import — a flake
# input, a store path, or a fetchTree result. Default (null): the revision
# pinned in this flake's own flake.lock, so existing callers are unchanged.
# Consumers that override igloo's nixpkgs-master input (e.g. nixos-26.05 for
# x86_64-darwin, which nixpkgs 26.11 dropped) cannot reach that lock from
# outside, so they pass their input through:
#   import igloo { inherit system; nixpkgs = nixpkgs-master; overlays = [ ... ]; }
{
  system ? builtins.currentSystem,
  overlays ? [ ],
  config ? { },
  nixpkgs ? null,
  ...
}@args:
let
  flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
  nixpkgsLock = flakeLock.nodes."nixpkgs-master".locked;
  nixpkgsSrc =
    if nixpkgs != null then
      nixpkgs
    else
      builtins.fetchTree {
        type = "github";
        inherit (nixpkgsLock) owner;
        inherit (nixpkgsLock) repo;
        inherit (nixpkgsLock) rev;
        inherit (nixpkgsLock) narHash;
      };
  lib = import "${nixpkgsSrc}/lib";
  forkOverlay = lib.composeManyExtensions (import ./overlays lib);
in
import nixpkgsSrc (
  removeAttrs args [ "nixpkgs" ]
  // {
    inherit system;
    overlays = [ forkOverlay ] ++ overlays;
    config = config // {
      allowUnfree = config.allowUnfree or true;
    };
  }
)
