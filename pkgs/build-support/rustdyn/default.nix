# rustdyn — per-crate content-addressed Rust builder (FDR 0009), godyn's
# counterpart for cargo workspaces: a unit graph derived at eval time from
# `cargo metadata` run inside a derivation, one CA derivation per crate through
# nixpkgs' buildRustCrate, per-crate test and clippy lanes, the layered install
# derivation and the fleet's version-through-build-script convention. Returns
# the attrs the overlay (overlays/amarbel-packages.nix) inherits flat:
#   buildRustdynWorkspace — the builder (callPackage build-rustdyn-workspace.nix)
#   buildRustAuto         — pick rustdyn vs buildRustPackage by strategy / system
#   rustdynSystems        — where buildRustAuto defaults to rustdyn
{ callPackage, godynSystems }:
rec {
  # The systems where rustdyn is the default Rust builder: igloo's builder
  # systems, the same list as godyn's (one place to edit for igloo#33; gated
  # builds run on x86_64-linux only, the other systems are unvalidated).
  rustdynSystems = godynSystems;
  buildRustdynWorkspace = callPackage ./build-rustdyn-workspace.nix { };
  buildRustAuto = callPackage ./build-rust-auto.nix { inherit buildRustdynWorkspace rustdynSystems; };
}
