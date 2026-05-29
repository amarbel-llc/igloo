# Cache entry creator for bun packages.
#
# Uses bun's specific wyhash implementation to calculate the correct
# location in which to place a cache entry for a given package after
# the tarball has been downloaded and extracted.
#
# This is a Zig binary built from the upstream bun2nix repo. It must
# be provided by the caller (e.g., from the bun2nix flake packages).
{ cacheEntryCreator }:
cacheEntryCreator
