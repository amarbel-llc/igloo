# mkGoPkgs — canonical producer-side helper for the flake-input-go_mod
# protocol (RFC 0001 § Producer interface).
#
# Returns the two flake outputs RFC 0001 mandates:
#
#   go-pkgs       — prod shape: *.go (excluding *_test.go), module
#                   files, workspace files, plus caller-supplied
#                   `extras`. Downstream prod consumers bridge against
#                   this by default.
#
#   go-pkgs-test  — superset: go-pkgs + *_test.go + testdata/** +
#                   caller-supplied `testExtras`. Used for self-
#                   consumption (a producer building itself from its
#                   own published artifact, exercising its own tests)
#                   and for downstream consumers that need to run the
#                   producer's tests against the bridged source.
#
# Implementation notes (informed by madder#212's inline contract test):
#
# 1. The testdata predicate matches both root-anchored (`^testdata/.*`,
#    for repos with a top-level `testdata/`) and nested
#    (`.*/testdata/.*`, for fixtures under internal packages). Both
#    patterns are needed in the same convention because Go module
#    layouts differ between single-module-at-root and subdirectory
#    producers.
#
# 2. The `runCommand` wrap is essentially free (<1s on madder's first
#    eval); `preferLocalBuild = true` + `allowSubstitutes = false`
#    keeps the wrap-step cheap and local.
#
# 3. The contract test for this helper is *self-consumption*: a
#    producer's own `buildGoApplication { src = pkgs.go-pkgs-test;
#    pwd = pkgs.go-pkgs-test; }` builds and tests cleanly. Without
#    self-consumption a producer can publish `go-pkgs-test` that
#    subtly fails downstream and never notice. RFC 0001 § Producer
#    interface carries the corresponding SHOULD recommendation.
{ lib, runCommand }:
let
  # Build a derivation containing the files of `src` that satisfy
  # `predicate`, always traversing directories. The predicate receives
  # the source-tree-relative path of each non-directory file. Optional
  # `passthru` is forwarded to the resulting derivation so callers can
  # attach metadata (e.g. `goFlakeInputs` per RFC 0001 § Producer-side
  # passthru inheritance, addressing amarbel-llc/nixpkgs#36).
  filteredTree =
    {
      name,
      src,
      predicate,
      passthru ? { },
    }:
    let
      origSrc = if src ? origSrc then src.origSrc else src;
      filteredPath = builtins.path {
        inherit name;
        path = origSrc;
        filter =
          path: type:
          let
            relPath = lib.removePrefix (toString origSrc + "/") (toString path);
          in
          type == "directory" || predicate relPath;
      };
    in
    runCommand name {
      preferLocalBuild = true;
      allowSubstitutes = false;
      inherit passthru;
    } ''
      cp -r ${filteredPath} $out
    '';

  mkGoPkgs =
    {
      src,
      # Optional explicit override for the output store-path prefix.
      # When omitted, the helper picks a name from (in order):
      #   1. `src.name` if `src` is a `cleanSourceWith`-like attrset
      #      (rarely set for flake-input sources)
      #   2. The last path element of `module <path>` in
      #      `${src}/go.mod`, if that file is readable at eval time
      #      without forcing IFD (typically: when `src` resolves to a
      #      path already in the store — flake inputs, `./.`-style
      #      paths, etc.)
      #   3. The fallback string "source".
      #
      # Adopters with polyglot layouts (`src = self + "/go"`) typically
      # set `name` explicitly to get a repo-prefixed store path —
      # otherwise the go.mod inference yields the last path element,
      # which for `module github.com/owner/repo/go` is just `"go"`.
      # See amarbel-llc/nixpkgs#49 for the motivating discussion.
      name ? null,
      # Extra regex patterns added to BOTH outputs (e.g. embedded
      # assets, top-level config files referenced by //go:embed).
      extras ? [ ],
      # Extra regex patterns added ONLY to go-pkgs-test (e.g. fixtures
      # outside the testdata/ convention).
      testExtras ? [ ],
      # OPTIONAL declarations of this producer's own cross-flake Go
      # module dependencies (same shape as consumer-side
      # `goFlakeInputs`). When non-empty, attached as
      # `passthru.goFlakeInputs` on BOTH outputs so downstream
      # consumers' bridge can union them transitively (depth-N) per
      # RFC 0001 § Multi-producer closures (amarbel-llc/igloo#58).
      goFlakeInputs ? { },
    }:
    let
      # Infer a name from go.mod's `module <path>` directive, taking
      # the last path element. Guarded by `pathExists` so missing
      # go.mod files cleanly fall through to "source" without throwing.
      inferredName =
        if !(builtins.pathExists (src + "/go.mod")) then
          "source"
        else
          let
            goMod = builtins.readFile (src + "/go.mod");
            match = builtins.match ".*\nmodule[ \t]+([^ \t\n]+).*" ("\n" + goMod);
          in
          if match == null then
            "source"
          else
            lib.last (lib.splitString "/" (lib.head match));

      baseName =
        if name != null then
          name
        else if src ? name then
          src.name
        else
          inferredName;

      isExtra = relPath: lib.any (re: builtins.match re relPath != null) extras;
      isTestExtra = relPath: lib.any (re: builtins.match re relPath != null) testExtras;

      isProdGoFile =
        relPath:
        lib.hasSuffix ".go" relPath
        && !lib.hasSuffix "_test.go" relPath;

      isTestGoFile = relPath: lib.hasSuffix "_test.go" relPath;

      isTestdataFile =
        relPath:
        builtins.match ".*/testdata/.*" relPath != null
        || builtins.match "^testdata/.*" relPath != null;

      # Module files kept in BOTH outputs.
      #
      # - go.mod / go.sum / gomod2nix.toml: matched by basename anywhere
      #   in the tree (except under testdata/). go.work-based workspaces
      #   carry a child go.mod/go.sum at each `use` directive's target;
      #   self-consumption fails if the child files are filtered out
      #   (gomod2nix opens them when walking the workspace). See
      #   amarbel-llc/nixpkgs#47.
      # - go.work / go.work.sum: matched only at the root (these files
      #   only ever live at the workspace root).
      #
      # The under-testdata exclusion uses `isTestdataFile` so the
      # under-testdata definition stays in one place.
      isModuleFile =
        relPath:
        (
          lib.elem (baseNameOf relPath) [
            "go.mod"
            "go.sum"
            "gomod2nix.toml"
          ]
          && !isTestdataFile relPath
        )
        || lib.elem relPath [
          "go.work"
          "go.work.sum"
        ];

      # version.env carries the release version (eng-versioning(7),
      # amarbel-llc/nixpkgs#31). Keeping it in the filtered tree lets
      # buildGoApplication's version.env auto-read find the package-local
      # file when a producer self-consumes its own go-pkgs / go-pkgs-test
      # artifact (pwd = filtered tree) — so producers get version
      # embedding for free without threading `version` through by hand.
      # Matched by basename anywhere except under testdata/: polyglot
      # repos keep one per package dir, and a testdata fixture's
      # version.env must not be promoted (mirrors isModuleFile's #47
      # exclusion).
      isVersionEnvFile =
        relPath:
        baseNameOf relPath == "version.env" && !isTestdataFile relPath;

      prodPredicate =
        relPath:
        isProdGoFile relPath
        || isModuleFile relPath
        || isVersionEnvFile relPath
        || isExtra relPath;

      testPredicate =
        relPath:
        prodPredicate relPath
        || isTestGoFile relPath
        || isTestdataFile relPath
        || isTestExtra relPath;

      # Surface goFlakeInputs through passthru only when the caller
      # actually declared cross-flake deps. Skipping the attribute
      # (rather than attaching {}) keeps consumers' `?` checks
      # well-defined for adopters who never bridge.
      passthru = lib.optionalAttrs (goFlakeInputs != { }) { inherit goFlakeInputs; };
    in
    {
      go-pkgs = filteredTree {
        name = "${baseName}-go-pkgs";
        inherit src passthru;
        predicate = prodPredicate;
      };

      go-pkgs-test = filteredTree {
        name = "${baseName}-go-pkgs-test";
        inherit src passthru;
        predicate = testPredicate;
      };
    };
in
{
  inherit mkGoPkgs;
}
