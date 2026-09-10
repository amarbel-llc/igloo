{ lib, ... }:
{
  # gomod2nix (from eng-impure) self-gates when there is no go.mod at the
  # tree root — igloo root has none; the gomod2nix sub-packages each carry
  # their own go.mod under pkgs/build-support/gomod2nix/.

  # git-remotes (from eng-impure) demands SSH origins, but the fleet now
  # talks to the forge over https: spinclass worktrees rewrite
  # git@code.linenisgreat.com: to https via a per-worktree insteadOf, so the
  # check fails every merge gate here regardless of the configured URL.
  linters.git-remotes.enable = lib.mkForce false;
}
