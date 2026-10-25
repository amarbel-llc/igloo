# version-env — the fleet's version.env convention (eng-versioning(7) § VERSION
# EMBEDDING) in one place, shared by buildGoApplication, buildGodynModule and
# buildRustdynWorkspace so the three builders cannot drift on what counts as a
# version.env. Pure: `import ./. { inherit lib; }`.
#
#   versionFromEnv dir            -> "1.2.3" | null
#   resolveVersion { version; dir; fallback } -> explicit > version.env > fallback
#   commitOf src                  -> src.rev | src.shortRev | "unknown"
{ lib }:
rec {
  # The value of the first `<NAME>_VERSION=<value>` assignment in
  # `<dir>/version.env`, read at evaluation time. A leading `export` and any
  # other lines (comments, other variables) are ignored; the value is one
  # whitespace-delimited token. null when the file is absent or has no such
  # line, so callers fall through to their own default. `dir` may be a path or
  # a store-path string.
  versionFromEnv =
    dir:
    let
      file = "${toString dir}/version.env";
      lineMatch =
        l: builtins.match "(export[[:space:]]+)?[A-Za-z0-9_]*_VERSION=([^[:space:]]+)[[:space:]]*" l;
      hits = lib.filter (m: m != null) (map lineMatch (lib.splitString "\n" (builtins.readFile file)));
    in
    if builtins.pathExists file && hits != [ ] then builtins.elemAt (builtins.head hits) 1 else null;

  # The builders' shared resolution order: an explicit `version` argument wins
  # (explicit beats implicit); else version.env in `dir`; else `fallback`
  # ("dev" unless the caller has a better default, e.g. the lockfile's module
  # version).
  resolveVersion =
    {
      version ? null,
      dir,
      fallback ? "dev",
    }:
    if version != null then
      version
    else
      let
        v = versionFromEnv dir;
      in
      if v != null then v else fallback;

  # The commit a build embeds: the flake input's rev (or shortRev), "unknown"
  # for a path or a source without one.
  commitOf = src: if lib.isAttrs src then (src.rev or src.shortRev or "unknown") else "unknown";
}
