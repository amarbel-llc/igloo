# godyn — a from-scratch per-package Go builder (one content-addressed derivation
# per package, scheduled by nix's own merkle-delta; no recursive-nix). Returns the
# attrs the overlay (overlays/amarbel-packages.nix) inherits flat:
#   buildGodynModule  — the builder (callPackage build-godyn-module.nix)
#   buildGoAuto       — pick godyn (dev) vs buildGoApplication (ci) by strategy
#   godyn-gen         — the dev-time graph generator CLI
#   godynStdlib       — the shared CGO_ENABLED=1 stdlib derivation
{ callPackage }:
let
  # goFlakeInputs resolution (RFC 0001, incl. depth-N inheritance) is shared with
  # buildGoApplication so both backends see the same bridge set.
  gomod2nixInternals = import ../gomod2nix/internals.nix { };
in
rec {
  godynStdlib = callPackage ./stdlib.nix { };
  godyn-gen = callPackage ./gen { };
  godyn-lint = callPackage ./lint { };
  buildGodynModule = callPackage ./build-godyn-module.nix {
    stdlib = godynStdlib;
    inherit gomod2nixInternals godyn-lint;
  };
  # buildGodynLint: the per-package lint lane of a buildGodynModule — takes the same
  # args (plus lintTool) and returns the manifest realising every local package's
  # lint derivation; wire it as a flake check.
  buildGodynLint = args: (buildGodynModule args).passthru.lintAll;
  # callPackage supplies buildGodynModule + buildGoApplication from the overlay.
  buildGoAuto = callPackage ./build-go-auto.nix { inherit buildGodynModule; };
}
