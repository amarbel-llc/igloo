# Source-tree filter for the go-pkgs producer convention (RFC 0001).
# Returns a *derivation* whose output is the filtered tree of `src` —
# keeps Go-relevant regular files (matched against the default keep-set
# or caller-supplied `extras` regex patterns). Directories are always
# traversed so the filter composes on deep trees; empty directories
# that have no matching descendants are preserved in the output
# (harmless for `go build`).
#
# Patterns are POSIX extended regex (builtins.match semantics), NOT
# globs. Examples: "^doc/.*" "^VERSION$" ".*\\.tmpl$".
#
# Implementation notes:
#
# 1. `lib.sources.sourceByRegex` applies the regex list to both files
#    and directories, so deep trees fail to traverse unless every
#    intermediate directory also matches some regex. To keep the
#    user-facing contract simple (the regex list is matched against
#    files only) this helper applies the directory-always-allow rule
#    in its own predicate.
#
# 2. Three flake-schema gates apply at three different layers:
#    - `nix eval` accepts any value.
#    - `nix build .#go-pkgs` accepts derivations, paths, or
#      strings-with-context that look like store paths.
#    - `nix flake check` is strictest: the value MUST be a derivation
#      (`lib.isDerivation` returns true; equivalent to checking for
#      `type = "derivation"`).
#
#    A bare `lib.cleanSourceWith` invocation returns a set with
#    `outPath`, which fails the `nix build` gate (see
#    amarbel-llc/nixpkgs#38). A bare `builtins.path` invocation
#    returns a string-with-context, which passes `nix build` but
#    fails `nix flake check` (see amarbel-llc/nixpkgs#44).
#
#    To satisfy all three gates this helper wraps the filtered
#    `builtins.path` result in a `runCommand` derivation that copies
#    the filtered tree into `$out`. `preferLocalBuild = true` +
#    `allowSubstitutes = false` keeps the wrap-step cheap and local.
{ lib, runCommand }:
let
  defaultRegexes = [
    ".*\\.go$"
    # go.mod / go.sum / gomod2nix.toml: matched by basename anywhere
    # in the tree, so go.work-based workspaces' child module files
    # (e.g. libs/dewey/go.mod) are kept alongside the root. See
    # amarbel-llc/nixpkgs#48 for the workspace failure mode under
    # the prior root-anchored regexes. `builtins.match` is anchored
    # at both ends, so `(.*/)?` covers both root and nested cases.
    "(.*/)?go\\.mod$"
    "(.*/)?go\\.sum$"
    "(.*/)?gomod2nix\\.toml$"
    # go.work and go.work.sum are load-bearing for go.work-based
    # multi-module workspaces. They only ever live at the workspace
    # root by Go's design, so keep them root-anchored. Single-module
    # producers are unaffected — these regexes match nothing in trees
    # that have no go.work file. See amarbel-llc/nixpkgs#45.
    "^go\\.work$"
    "^go\\.work\\.sum$"
  ];

  goSourceFilter =
    {
      src,
      extras ? [ ],
    }:
    let
      regexes = defaultRegexes ++ extras;
      # Unwrap an already-filtered src so the relative-path computation
      # stays anchored at the original source root when composing.
      origSrc = src.origSrc or src;
      name = src.name or "source";
      filteredPath = builtins.path {
        inherit name;
        path = origSrc;
        filter =
          path: type:
          let
            relPath = lib.removePrefix (toString origSrc + "/") (toString path);
          in
          type == "directory" || lib.any (re: builtins.match re relPath != null) regexes;
      };
    in
    runCommand name
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        cp -r ${filteredPath} $out
      '';

  goSourceFilterMiddleware = src: goSourceFilter { inherit src; };
in
{
  inherit goSourceFilter goSourceFilterMiddleware;
}
