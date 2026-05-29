# shellcheck shell=bash
#
# Wraps go subcommands that mutate go.mod/go.sum to auto-regenerate
# gomod2nix.toml afterward. Sourced via etc/profile.d in devshells.
#
# Guard: skip inside Nix build sandboxes (NIX_BUILD_TOP is set there)
# but activate under both interactive `nix develop` and
# `nix develop --command <cmd>` where PS1 may be unset.
if [ -z "${NIX_BUILD_TOP-}" ]; then
  go() {
    command go "$@"
    local _exit=$?
    if [ $_exit -eq 0 ]; then
      case "${1:-} ${2:-}" in
      "get "* | "mod tidy" | "mod init" | "mod edit" | "work sync")
        echo "[gomod2nix] regenerating gomod2nix.toml..." >&2
        command gomod2nix generate
        ;;
      esac
    fi
    return $_exit
  }
fi
