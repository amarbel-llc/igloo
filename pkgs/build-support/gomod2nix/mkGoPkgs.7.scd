mkGoPkgs(7) ["amarbel-llc/igloo"]

# NAME

mkGoPkgs - canonical producer-side helper for the flake-input-go_mod protocol

# SYNOPSIS

```
inherit (pkgs.mkGoPkgs { src = self; }) go-pkgs go-pkgs-test;

packages.${system} = {
  inherit go-pkgs go-pkgs-test;
};
```

# DESCRIPTION

*pkgs.mkGoPkgs* is the canonical entry point for the producer side of
the flake-input-go_mod protocol (RFC 0001). It returns the two flake
outputs the protocol mandates from a single call: a prod-shape
*go-pkgs* (excludes test files and testdata fixtures) and a
test-superset *go-pkgs-test*.

Both outputs are real derivations (*lib.isDerivation* true) and
therefore pass *nix flake check*'s schema gate (see amarbel-llc/nixpkgs#44
for the gate that bare *goSourceFilter* / bare *self* / *self.outPath*
all fail).

# ARGUMENTS

- *src* — REQUIRED. A path or derivation containing the Go source
  tree. For polyglot repos with the Go module under a subdirectory,
  pass *self + "/go"*.
- *name* — OPTIONAL explicit override for the output store-path
  prefix. When omitted, falls through (in order) to *src.name* (when
  *src* is a cleanSourceWith-like attrset), then to the last path
  element of the *module* directive in *${src}/go.mod*, then to
  *"source"*. Adopters with polyglot layouts (*src = self + "/go"*)
  typically set *name* explicitly to get a repo-prefixed store path
  (otherwise the inference yields just *"go"*). See
  amarbel-llc/nixpkgs#49.
- *extras* — OPTIONAL list of POSIX extended-regex strings added to
  the keep-set of *both* outputs. Use for files relevant to both
  prod and test builds (e.g. embedded asset directories, top-level
  config files referenced by *//go:embed*).
- *testExtras* — OPTIONAL list of POSIX extended-regex strings added
  only to *go-pkgs-test*. Use for fixtures that live outside the
  default *testdata* convention.
- *goFlakeInputs* — OPTIONAL attrset declaring this producer's own
  cross-flake Go module dependencies (same shape as the consumer-side
  *goFlakeInputs* argument to *buildGoApplication*/*mkGoEnv*). When
  non-empty, attached as *passthru.goFlakeInputs* on BOTH outputs so
  downstream consumers' bridge can union them at depth-1 per
  RFC 0001 § *Multi-producer closures*. Omit (or pass an empty
  attrset) when the producer has no cross-flake deps; in that case
  the attribute is left off entirely so consumer code can probe
  *passthru ? goFlakeInputs* unambiguously. See
  amarbel-llc/nixpkgs#36.

# OUTPUTS

*go-pkgs* is the prod shape. It contains all Go source files except
those ending in \_test.go; the module files (go.mod, go.sum,
gomod2nix.toml) matched by basename anywhere in the tree (except
under testdata), so go.work-based workspaces' child module files
survive; the workspace files (go.work, go.work.sum) at the source
root; any *version.env* files (matched by basename anywhere except
under testdata — see *version.env* below); and whatever paths
*extras* additionally matches. Downstream prod consumers bridge
against this output by default.

*go-pkgs-test* is the test superset. It contains everything in
*go-pkgs*, plus test files (those ending in \_test.go), plus
testdata directory contents at any depth (matched both root-anchored
and nested, so single-module-at-root and subdirectory layouts both
work), plus whatever paths *testExtras* additionally matches. Used
for self-consumption (a producer building itself from its own
published artifact, exercising its own tests) and for downstream
consumers that need the producer's tests against the bridged source.

# SELF-CONSUMPTION

A producer SHOULD point its own *buildGoApplication*'s *src* and
*pwd* at its *go-pkgs-test* output:

```
let
  goPkgs = pkgs.mkGoPkgs { src = self; };
in {
  packages.${system} = {
    inherit (goPkgs) go-pkgs go-pkgs-test;
    default = pkgs.buildGoApplication {
      pname = "my-app";
      src = goPkgs.go-pkgs-test;
      pwd = goPkgs.go-pkgs-test;
      modules = ./gomod2nix.toml;
      # checkPhase runs `go test ./...` against the filtered tree —
      # contract test that catches publish-but-broken cases for
      # downstream consumers.
    };
  };
}
```

A producer that does not self-consume can publish a *go-pkgs-test*
that subtly fails downstream (missing a fixture, an embed asset, a
workspace file) and never notice. Self-consumption turns "the
published tree is valid" from a documentation claim into a build
invariant. See *RFC 0001 § Self-consumption SHOULD* for the
normative recommendation and madder#212 for the originating adopter
experience.

The *modules* argument is a producer-discretion call:

- *modules = ./gomod2nix.toml* (worktree-relative): evaluates faster
  at flake-eval time
- *modules = "${goPkgs.go-pkgs-test}/gomod2nix.toml"*
  (filtered-tree-relative): stronger contract; drift between the
  worktree's lockfile and the filter's view becomes structurally
  impossible

Either form satisfies the protocol.

## version.env

*mkGoPkgs* keeps *version.env* files in both outputs (by basename,
anywhere except under *testdata*). This dovetails with
*buildGoApplication*'s version.env auto-read (gomod2nix(7) § VERSION
AND COMMIT INJECTION): because the file survives into *go-pkgs* /
*go-pkgs-test*, a self-consuming producer whose *pwd* points at the
filtered tree gets version embedding for free — no *version*
threading and no *extras* entry for the file. Polyglot repos keep one
*version.env* per package dir; each is preserved at its original path,
so a per-module *buildGoApplication* picks up the package-local file.

# gomod.nix CONVENTION

*mkGoPkgs* is typically called from a *gomod.nix* file (the Nix
interface to *go.mod*) that captures the flake's Go-side surface:

```
# gomod.nix — pure producer
{ pkgs, src }:
pkgs.mkGoPkgs {
  inherit src;
  extras = [ ];
  testExtras = [ ];
}
```

```
# gomod.nix — mixed producer + consumer
{ pkgs, src, tap, tommy, system }: {
  goPkgs = pkgs.mkGoPkgs { inherit src; };
  goFlakeInputs = {
    "github.com/amarbel-llc/tap/go" = {
      src = tap.packages.${system}.go-pkgs;
      subPath = "go";
    };
    "github.com/amarbel-llc/tommy" = {
      src = tommy.packages.${system}.go-pkgs;
    };
  };
}
```

See *RFC 0001 § The gomod.nix convention* for the normative spec.

# //go:embed ASSETS

Any file that *//go:embed* references but that the default keep-set
doesn't already cover (i.e. anything other than *.go*, the module
files, *testdata/**)* must be added to *extras* (prod and test) or
*testExtras* (test only) by hand. The failure mode is loud — the
build fails with *pattern X: no matching files found* — but the fix
is split across two files, which is exactly the toil RFC 0001 set
out to eliminate.

A typical *gomod.nix* for a producer that *//go:embed*s template,
asset, and test fixture files:

```
pkgs.mkGoPkgs {
  inherit src;
  extras = [
    "^cmd/example/templates/.*$"   # //go:embed templates/*.tmpl
    "^cmd/example/assets/.*$"      # //go:embed all:assets
  ];
  testExtras = [
    "^cmd/example/fixtures/.*$"    # //go:embed in *_test.go
  ];
}
```

Each regex is matched against source-tree-relative paths (no leading
slash). Patterns inside *testdata/* are kept automatically by
*go-pkgs-test* — they only need *testExtras* when they live outside
the convention.

Auto-deriving *extras* from *//go:embed* directives is parked on
amarbel-llc/nixpkgs#60. A regex-based scanner in Nix is too fragile
(quoted patterns, build tags, comments-in-strings), and a Go-AST
helper is heavier than the manual two-line tax it would replace.
The right place to revisit this is a future go2nix integration that
already parses the AST for other reasons.

# RELATIONSHIP TO goSourceFilter

*pkgs.goSourceFilter* is the lower-level primitive that filters a
single source tree according to a flat regex keep-set.
*pkgs.mkGoPkgs* builds on top of the same *builtins.path* +
*runCommand* shape but applies the dual-output convention from RFC
0001's producer interface (prod vs. test split, plus self-consumption
contract). Producers SHOULD use *mkGoPkgs*; *goSourceFilter* remains
available for single-output cases and as an open building block.

# LIMITATIONS

- *extras* and *testExtras* use regex, not globs.
- Empty directories with no matching descendants are preserved in
  the filtered output (a consequence of always-traversing
  directories); this is harmless for *go build* but slightly inflates
  the output NAR.
- The middleware-aware variant (*mkGoPkgsWithMiddleware*, provisional
  name) is **not yet implemented**. Producers needing codegen today
  inline middleware steps in their flake and publish the result as
  *go-pkgs* / *go-pkgs-test* directly. See *RFC 0001 § Producers with
  codegen (deferred)*.
- *go.work* / *go.work.sum* are matched at the source root only.
  Workspaces with deeply-nested *go.work* files (which Go does not
  support) are not supported.
- Multi-module repos with multiple distinct Go modules at sibling
  paths can publish only one pair of *go-pkgs* / *go-pkgs-test*
  outputs. A naming convention for additional pairs
  (*go-pkgs-<module-name>*) is unspecified.

# SEE ALSO

*gomod2nix*(7), *goSourceFilter*(7), *lib.sources.sourceByRegex*,
*docs/rfcs/0001-flake-input-go_mod.md*.
