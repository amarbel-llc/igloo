# rustdyn-cargo — the escape hatch CLI for cargo.nix (FDR 0009 stage 2.5), the
# godyn-go twin: a thin wrapper over nix.
#
#   rustdyn-cargo [-A <attr>] [-m <cargo.nix>] [-n] -- <cargo command...>
#   rustdyn-cargo [-m <cargo.nix>] -I <dir>
#
# Builds <attr>.passthru.cargoRun { command } from a git+file: flake ref of the
# repository (tracked files as in the working tree; a new file needs
# `git add -N` first; .git and ignored dirs never copied): an impure derivation
# that runs the command against the rendered manifests with the network
# available. Then applies the run's patch to the checkout (`git apply --check`
# first: if a touched file changed meanwhile nothing is written and the patch's
# store path is printed) and rewrites <cargo.nix> from passthru.ingest. -n stops
# after the build and prints the output path.
#
# -I <dir> only ingests: <dir>'s Cargo.toml files and Cargo.lock become
# <cargo.nix>, versions equal to <dir>'s version.env dropped, flakeInputs seeded
# from the existing <cargo.nix> when there is one. That is the migration of a
# tracked workspace: `rustdyn-cargo -I .`, then remove Cargo.toml and
# Cargo.lock. It needs no flake attribute: the manifest library runs directly.
{
  lib,
  writeShellApplication,
  nix,
  git,
  jq,
  path,
}:
let
  # the manifest library and what it imports, for -I (no flake attribute involved)
  # (this file sits in rustdyn/ itself, unlike godyn's go-cli/ subdirectory)
  manifestLib = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./manifest.nix
      ../version-env/default.nix
    ];
  };
in
writeShellApplication {
  name = "rustdyn-cargo";
  runtimeInputs = [
    nix
    git
    jq
  ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: rustdyn-cargo [-A <attr>] [-m <cargo.nix>] [-n] -- <cargo command...>
           rustdyn-cargo [-m <cargo.nix>] -I <dir>
      -A <attr>      the workspace's flake attribute (default: packages.<system>.default)
      -m <cargo.nix> the manifest to rewrite (default: ./cargo.nix)
      -n             build only: print the cargoRun output path on stdout, apply nothing
      -I <dir>       ingest only: <dir>'s Cargo.toml files + Cargo.lock into <cargo.nix>
                     (flakeInputs seeded from the existing <cargo.nix>, if any)
    EOF
    }
    attr=""
    manifest="cargo.nix"
    apply=1
    ingestDir=""
    while getopts ":A:m:nI:h" opt; do
      case "$opt" in
        A) attr=$OPTARG ;;
        m) manifest=$OPTARG ;;
        n) apply=0 ;;
        I) ingestDir=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
      esac
    done
    shift $((OPTIND - 1))

    write_manifest() {
      local new=$1
      if [ -f "$manifest" ] && [ "$new" = "$(cat "$manifest")" ]; then
        echo "rustdyn-cargo: $manifest unchanged" >&2
      else
        printf '%s' "$new" > "$manifest"
        echo "rustdyn-cargo: wrote $manifest" >&2
      fi
    }

    if [ -n "$ingestDir" ]; then
      [ "$#" -eq 0 ] || { usage; exit 2; }
      seed="{ }"
      [ ! -f "$manifest" ] || seed="import $(realpath "$manifest")"
      lib="(import ${path} { }).callPackage ${manifestLib}/rustdyn/manifest.nix { }"
      new=$(nix eval --impure --raw --expr "($lib).renderCargoNix (($lib).ingestTree {
        tree = \"$(realpath "$ingestDir")\";
        seed = $seed;
      })")
      write_manifest "$new"
      exit 0
    fi

    [ "$#" -gt 0 ] || { usage; exit 2; }
    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    [ -n "$attr" ] || attr="packages.$system.default"
    # git+file: copies only tracked files (modified contents included), never
    # .git or ignored dirs like .tmp; a new file needs `git add -N` first.
    flake="(builtins.getFlake \"git+file:$(git rev-parse --show-toplevel)\").$attr.passthru"
    # the command, shell-quoted for the derivation's bash
    command=$(printf '%q ' "$@")
    expr="$flake.cargoRun { command = $(printf '%s' "$command" | jq -Rs .); }"
    out=$(nix build --impure --no-link --print-out-paths --expr "$expr")
    echo "rustdyn-cargo: $out" >&2
    # -n: the output path is the result, on stdout
    [ "$apply" -eq 1 ] || { echo "$out"; exit 0; }

    if [ -s "$out/patch" ]; then
      prefix=$(git rev-parse --show-prefix)
      if ! git apply --check -p2 --directory="$prefix" "$out/patch"; then
        echo "rustdyn-cargo: the checkout changed under the patch; nothing written. Patch: $out/patch" >&2
        exit 1
      fi
      git apply -p2 --directory="$prefix" "$out/patch"
      echo "rustdyn-cargo: applied $out/patch" >&2
    fi

    write_manifest "$(nix eval --impure --raw --expr "$flake.ingest \"$out\"")"
  '';
}
