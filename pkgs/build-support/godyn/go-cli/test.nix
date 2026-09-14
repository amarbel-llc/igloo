# godyn-test — the inner test loop CLI (FDR 0008), a thin wrapper over nix.
#
#   godyn-test [-A <attr>] <dir> [-- <test binary flags...>]
#
# Builds <attr>.passthru.testWith { dir; testFlags } from a git+file: flake ref
# of the repository (tracked files as in the working tree; a new file needs
# `git add -N` first), so only the edited cone rebuilds, then prints the run's
# test.log and exits 0 on "ok",
# 1 on "FAIL". Flags are the test binary's (-test.run=TestX -test.v -test.count=1).
{
  writeShellApplication,
  nix,
  jq,
}:
writeShellApplication {
  name = "godyn-test";
  runtimeInputs = [
    nix
    jq
  ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: godyn-test [-A <attr>] <dir> [-- <test binary flags...>]
      -A <attr>  the module's flake attribute (default: packages.<system>.default)
      <dir>      the tested package, module-relative ("." for the root package)
      flags      test binary flags, e.g. -test.run=TestX -test.v
    EOF
    }
    attr=""
    while getopts ":A:h" opt; do
      case "$opt" in
        A) attr=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
      esac
    done
    shift $((OPTIND - 1))
    [ "$#" -ge 1 ] || { usage; exit 2; }
    dir=$1
    shift
    [ "''${1:-}" != "--" ] || shift

    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    [ -n "$attr" ] || attr="packages.$system.default"
    # each flag as a nix string literal (json-escaped), space-separated
    flags=""
    for f in "$@"; do flags+="$(printf '%s' "$f" | jq -Rs .) "; done
    # git+file: copies only tracked files (modified contents included), never
    # .git or ignored dirs like .tmp; a new file needs `git add -N` first.
    expr="(builtins.getFlake \"git+file:$(git rev-parse --show-toplevel)\").$attr.passthru.testWith {
      dir = $(printf '%s' "$dir" | jq -Rs .);
      testFlags = [ $flags];
    }"
    out=$(nix build --impure --no-link --print-out-paths --expr "$expr")
    cat "$out/test.log"
    result=$(cat "$out/result")
    echo "$result" >&2
    case "$result" in
      ok\ *) exit 0 ;;
      *) exit 1 ;;
    esac
  '';
}
