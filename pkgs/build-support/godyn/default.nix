# godyn — a from-scratch per-package Go builder (one content-addressed derivation
# per package, scheduled by nix's own merkle-delta; no recursive-nix). Returns the
# attrs the overlay (overlays/amarbel-packages.nix) inherits flat:
#   buildGodynModule  — the builder (callPackage build-godyn-module.nix)
#   godyn-gen         — the dev-time graph generator CLI
#   godynStdlib       — the shared CGO_ENABLED=1 stdlib derivation
{ callPackage }:
rec {
  godynStdlib = callPackage ./stdlib.nix { };
  godyn-gen = callPackage ./gen { };
  buildGodynModule = callPackage ./build-godyn-module.nix { stdlib = godynStdlib; };
}
