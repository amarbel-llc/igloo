# godyn-go — the escape hatch CLI (FDR 0008), a thin wrapper over nix.
#
#   godyn-go [-A <attr>] [-m <go.nix>] [-n] -- <go command...>
#   godyn-go [-m <go.nix>] -I <dir>
#
# Builds <attr>.passthru.goRun { command } from a path: flake ref of the current
# directory (uncommitted and untracked files included): an impure derivation
# that runs the command against the rendered module with the network available.
# Then applies the run's patch to the checkout (`git apply --check` first: if a
# touched file changed meanwhile nothing is written and the patch's store path
# is printed) and rewrites <go.nix> from passthru.ingest. -n stops after the
# build and prints the output path.
#
# -I <dir> only ingests: <dir>'s go.mod and gomod2nix.toml become <go.nix>,
# seeded from the existing <go.nix> (its module, go and flakeInputs; a fleet
# module listed there is dropped from the requires). That is the migration of a
# go.mod module: `gomod2nix generate`, write the seed, `godyn-go -I .`, then
# remove go.mod, go.sum and gomod2nix.toml. It needs no flake attribute: the
# manifest library runs directly.
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
  manifestLib = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../manifest.nix
      ../../gomod2nix/parser.nix
      ../../gomod2nix/internals.nix
    ];
  };
in
writeShellApplication {
  name = "godyn-go";
  runtimeInputs = [
    nix
    git
    jq
  ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: godyn-go [-A <attr>] [-m <go.nix>] [-n] -- <go command...>
           godyn-go [-m <go.nix>] -I <dir>
      -A <attr>    the module's flake attribute (default: packages.<system>.default)
      -m <go.nix>  the manifest to rewrite (default: ./go.nix)
      -n           build only: print the goRun output path, apply nothing
      -I <dir>     ingest only: <dir>/go.mod + <dir>/gomod2nix.toml into <go.nix>,
                   seeded from the existing <go.nix> (module, go, flakeInputs)
    EOF
    }
    attr=""
    manifest="go.nix"
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
        echo "godyn-go: $manifest unchanged" >&2
      else
        printf '%s\n' "$new" > "$manifest"
        echo "godyn-go: wrote $manifest" >&2
      fi
    }

    if [ -n "$ingestDir" ]; then
      [ "$#" -eq 0 ] || { usage; exit 2; }
      [ -f "$manifest" ] || { echo "godyn-go: -I needs a seed $manifest (module, go, flakeInputs)" >&2; exit 2; }
      lib="(import ${path} { }).callPackage ${manifestLib}/godyn/manifest.nix { }"
      new=$(nix eval --impure --raw --expr "($lib).ingestGoNix {
        pname = \"godyn-go\";
        manifest = $(realpath "$manifest");
        out = \"$(realpath "$ingestDir")\";
      }")
      write_manifest "$new"
      exit 0
    fi

    [ "$#" -gt 0 ] || { usage; exit 2; }
    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    [ -n "$attr" ] || attr="packages.$system.default"
    flake="(builtins.getFlake \"path:$PWD\").$attr.passthru"
    # the command, shell-quoted for the derivation's bash
    command=$(printf '%q ' "$@")
    expr="$flake.goRun { command = $(printf '%s' "$command" | jq -Rs .); }"
    out=$(nix build --impure --no-link --print-out-paths --expr "$expr")
    echo "godyn-go: $out" >&2
    [ "$apply" -eq 1 ] || exit 0

    if [ -s "$out/patch" ]; then
      prefix=$(git rev-parse --show-prefix)
      if ! git apply --check -p2 --directory="$prefix" "$out/patch"; then
        echo "godyn-go: the checkout changed under the patch; nothing written. Patch: $out/patch" >&2
        exit 1
      fi
      git apply -p2 --directory="$prefix" "$out/patch"
      echo "godyn-go: applied $out/patch" >&2
    fi

    write_manifest "$(nix eval --impure --raw --expr "$flake.ingest \"$out\"")"
  '';
}
