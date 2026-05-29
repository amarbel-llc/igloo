{
  pkgs,
  pocLibSrc ? null,
}:
# Regression test for amarbel-llc/nixpkgs#33: mkVendorEnv must accept a
# gomod2nix.toml that contains only `schema = 3` (no [mod] table). This
# shape is valid when the consumer has zero organic deps — e.g. when
# goFlakeInputs handles every external import — but mkVendorEnv used to
# crash with `attribute 'mod' missing` because it accessed
# modulesStruct.mod unconditionally. The fix adds an `or { }` fallback
# at the access sites.
#
# We deliberately call mkGoEnv WITHOUT goFlakeInputs so the merge path
# is bypassed and the consumer's schema-only toml flows straight through
# to mkVendorEnv. pocLibSrc is accepted for `pkgs.callPackage`
# uniformity with the sibling tests but is unused here.
let
  emptyToml = pkgs.writeText "gomod2nix.toml" ''
    schema = 3
  '';
in
pkgs.mkGoEnv {
  pwd = ./.;
  modules = emptyToml;
}
