# Single source of truth for the igloo Go toolchain versions — see
# go-toolchain(7). `pkgs.goToolchain.go` tracks the NEWEST entry here; every
# entry also surfaces as a pinned `pkgs.go_<major>_<minor>_<patch>` attribute.
# nixpkgs' `pkgs.go` is never overridden (FDR 0012).
#
# APPEND-ONLY. Add a version with `just update-go <version>`, which
# prefetches the go<version>.src.tar.gz SRI hash and inserts a new entry below
# the end marker. Never rewrite or remove an existing entry: consumers pin the
# per-version attrs, so a removed entry breaks them.
#
# Each entry is `{ version = "<x.y.z>"; hash = "<sri>"; }`. A version whose Go
# minor nixpkgs does not package at all may instead carry a fork entry
# `{ version = "<x.y.z>"; goDrv = <a go derivation>; }` (see go-toolchain(7) §
# FORK ENTRIES); such an entry needs no hash and no nixpkgs base.
[
  {
    version = "1.26.3";
    hash = "sha256-HGRoddCqh5kTMYTtV895/yS97+jIggRwYCqdPW2Rkrg=";
  }
  {
    version = "1.26.6";
    hash = "sha256-oHIcVMaIkBRI13rZs+x+p8R0cwdV/4kTgukuy5P/LLE=";
  }
  {
    version = "1.26.8";
    hash = "sha256-Tjm5jkL5RvoFrIvFtxh335fb23y7Gnd7VBZnrXEX/S4=";
  }
  # @@GO_TOOLCHAIN_REGISTRY_END@@ — update-go inserts new entries above this
  # line; do not remove this marker, reorder entries, or rewrite an existing one.
]
