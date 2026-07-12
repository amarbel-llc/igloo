{ ... }:
{
  # gomod2nix (from eng-impure) self-gates when there is no go.mod at the
  # tree root — igloo root has none; the gomod2nix sub-packages each carry
  # their own go.mod under pkgs/build-support/gomod2nix/.
}
