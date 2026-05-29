# Zig binary used by `bun2nix.fetchBunDeps` to place cache entries at the
# paths Bun expects. Built from the upstream `nix-community/bun2nix` repo,
# pinned to the same commit the fork's bun.nix schema is known to work with.
#
# Keep this in lockstep with the `bun2nix` CLI that callers use to generate
# their `bun.nix` — the wyhash-derived cache layout must match.
{
  stdenvNoCC,
  fetchFromGitHub,
  callPackage,
  zig_0_15,
  lib,
}:

let
  # Release 2.0.8 (2026-02-12).
  rev = "c843f477b15f51151f8c6bcc886954699440a6e1";
  repoSrc = fetchFromGitHub {
    owner = "nix-community";
    repo = "bun2nix";
    inherit rev;
    hash = "sha256-v3QaK9ugy9bN9RXDnjw0i2OifKmz2NnKM82agtqm/UY=";
  };
  depsNix = repoSrc + "/programs/cache-entry-creator/deps.nix";
in
stdenvNoCC.mkDerivation {
  pname = "bun2nix-cache-entry-creator";
  version = "2.0.8";

  src = repoSrc + "/programs/cache-entry-creator";

  nativeBuildInputs = [ zig_0_15.hook ];

  postConfigure = ''
    ln -s ${callPackage depsNix { }} $ZIG_GLOBAL_CACHE_DIR/p
  '';

  zigBuildFlags = [ "--release=fast" ];

  doCheck = true;

  meta = {
    description = "Cache entry creator for bun packages";
    longDescription = ''
      Uses bun's specific wyhash implementation to calculate the correct
      location in which to place a cache entry for a given package after
      the tarball has been downloaded and extracted.
    '';
    mainProgram = "cache_entry_creator";
  };
}
