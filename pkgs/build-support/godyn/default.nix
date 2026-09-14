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
  # The systems where godyn is the default Go builder: every system igloo
  # supports (FDR 0007: godyn replaces buildGoApplication's output everywhere).
  # buildGoAuto's default strategy picks godyn here and buildGoApplication only
  # elsewhere; consumers never hard-code a system and key gates off
  # passthru.backend. Gated builds still run on x86_64-linux only — validating the
  # other systems on real builders is igloo#33.
  godynSystems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];
  godynStdlib = callPackage ./stdlib.nix { };
  godyn-gen = callPackage ./gen { };
  godyn-lint = callPackage ./lint { };
  # go.nix (FDR 0008): render go.mod/gomod2nix.toml from the manifest, resolve its
  # fleet modules through flake inputs, and read a go.mod back into a manifest.
  godynManifest = callPackage ./manifest.nix { };
  buildGodynModuleFromArgs = callPackage ./build-godyn-module.nix {
    stdlib = godynStdlib;
    inherit
      gomod2nixInternals
      godyn-lint
      godyn-gen
      godynManifest
      ;
  };
  # godyn-go: the escape hatch CLI (FDR 0008) — runs a go command in
  # passthru.goRun, applies its patch, and rewrites go.nix from passthru.ingest.
  godyn-go = callPackage ./go-cli { };
  # A go.nix consumer passes manifest (+ inputs, goFlakeInputOverrides) instead of
  # modules, goFlakeInputs and a tracked go.mod; every other arg is unchanged.
  buildGodynModule = args: buildGodynModuleFromArgs (godynManifest.withManifest args);
  # buildGodynLint: the per-package lint lane of a buildGodynModule — takes the same
  # args (plus lintTool) and returns the manifest realising every local package's
  # lint derivation; wire it as a flake check.
  buildGodynLint = args: (buildGodynModule args).passthru.lintAll;
  # callPackage supplies buildGodynModule + buildGoApplication from the overlay.
  buildGoAuto = callPackage ./build-go-auto.nix {
    inherit buildGodynModule godynSystems godynManifest;
  };
}
