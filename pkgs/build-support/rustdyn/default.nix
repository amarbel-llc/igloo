# rustdyn — per-crate content-addressed Rust builder (FDR 0009), godyn's
# counterpart for cargo workspaces: a unit graph derived at eval time from
# `cargo metadata` run inside a derivation, one CA derivation per crate through
# nixpkgs' buildRustCrate, per-crate test and clippy lanes, the layered install
# derivation and the fleet's version-through-build-script convention. Returns
# the attrs the overlay (overlays/amarbel-packages.nix) inherits flat:
#   buildRustdynWorkspace — the builder (callPackage build-rustdyn-workspace.nix)
#   buildRustAuto         — pick rustdyn vs buildRustPackage by strategy / system
#   rustdynSystems        — where buildRustAuto defaults to rustdyn
{ callPackage }:
rec {
  # The systems where rustdyn is the default Rust builder — the same list as
  # godynSystems. Gated builds run on x86_64-linux only; the other systems are
  # unvalidated on real builders (igloo#33's Rust twin).
  rustdynSystems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];
  buildRustdynWorkspace = callPackage ./build-rustdyn-workspace.nix { };
  buildRustAuto = callPackage ./build-rust-auto.nix { inherit buildRustdynWorkspace rustdynSystems; };
}
