# rustdyn — per-crate content-addressed Rust builder (FDR 0009), godyn's
# counterpart for cargo workspaces: a unit graph derived at eval time from
# `cargo metadata` run inside a derivation, one CA derivation per crate through
# nixpkgs' buildRustCrate, per-crate test and clippy lanes, the layered install
# derivation and the fleet's version-through-build-script convention. Returns
# the attrs the overlay (overlays/amarbel-packages.nix) inherits flat:
#   buildRustdynWorkspace — the builder (callPackage build-rustdyn-workspace.nix),
#                           accepting a cargo.nix `manifest` (stage 2.5)
#   buildRustAuto         — pick rustdyn vs buildRustPackage by strategy / system
#   rustdynManifest       — the cargo.nix library (resolve, render, ingest)
#   rustdynSystems        — where buildRustAuto defaults to rustdyn
{ callPackage, godynSystems }:
rec {
  # The systems where rustdyn is the default Rust builder: igloo's builder
  # systems, the same list as godyn's (one place to edit for igloo#33; gated
  # builds run on x86_64-linux only, the other systems are unvalidated).
  rustdynSystems = godynSystems;
  # cargo.nix (FDR 0009 stage 2.5): render Cargo.toml/Cargo.lock from the
  # manifest into the tree the builder reads, read a tree back into a manifest,
  # and reject a tracked Cargo.toml or Cargo.lock beside a cargo.nix.
  rustdynManifest = callPackage ./manifest.nix { };
  buildRustdynWorkspaceFromArgs = callPackage ./build-rustdyn-workspace.nix { };
  # A cargo.nix consumer passes manifest (+ inputs) instead of a tracked
  # Cargo.toml/Cargo.lock; every other argument is unchanged.
  buildRustdynWorkspace =
    args: buildRustdynWorkspaceFromArgs (rustdynManifest.withCargoManifest args);
  buildRustAuto = callPackage ./build-rust-auto.nix {
    inherit buildRustdynWorkspace rustdynSystems rustdynManifest;
  };
}
