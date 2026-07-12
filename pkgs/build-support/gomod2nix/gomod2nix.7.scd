gomod2nix(7) ["amarbel-llc/igloo"]

# NAME

gomod2nix - build helpers for Go applications using gomod2nix lockfiles

# SYNOPSIS

In a flake that builds a Go application:

```
pkgs = import nixpkgs { inherit system; };  # nixpkgs = "github:amarbel-llc/igloo"

pkgs.buildGoApplication { ... }
pkgs.mkGoEnv { pwd = ./.; }
```

# DESCRIPTION

*amarbel-llc/igloo* carries the gomod2nix build helpers natively. Flakes
that previously depended on *github:nix-community/gomod2nix* and its overlay
can drop that input entirely and use *pkgs.buildGoApplication* and
*pkgs.mkGoEnv* directly.

The public surface exposed on *pkgs* is:

- *buildGoApplication* — build a Go binary from a gomod2nix.toml lockfile
- *mkGoEnv* — create a vendor environment for devshells; propagates *go*,
  *gomod2nix* CLI, and the *go-sync-wrap* shell hook automatically
- *mkVendorEnv* — low-level: assemble a vendor/ directory from fetched modules
- *mkGoCacheEnv* — pre-warm the Go build cache as a derivation
- *gomod2nix* — the gomod2nix CLI binary (available via *mkGoEnv*; rarely
  needed explicitly)

# MIGRATING FROM nix-community/gomod2nix

## 1. Change the nixpkgs input

Replace the pinned upstream nixpkgs with igloo:

```
# Before
nixpkgs.url = "github:NixOS/nixpkgs/<pin>";

# After
nixpkgs.url = "github:amarbel-llc/igloo";
```

## 2. Remove the gomod2nix flake input

Delete the *gomod2nix* input block and its *follows* entries entirely:

```
# Remove:
gomod2nix = {
  url = "github:nix-community/gomod2nix";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-utils.follows = "utils";
};
```

Remove *gomod2nix* from the *outputs* function arguments too.

## 3. Remove the overlay

The *gomod2nix.overlays.default* overlay was the mechanism that injected
*buildGoApplication* into *pkgs*. It is no longer needed:

```
# Before
pkgs = import nixpkgs {
  inherit system;
  overlays = [
    gomod2nix.overlays.default
    (_: _: { go = pkgs-master.go; })
  ];
};

# After
pkgs = import nixpkgs { inherit system; };
```

The *go* version override in the overlay is also gone. See *GO VERSION
SELECTION* below for how the fork handles this.

## 4. Simplify the package derivation

*buildGoApplication* is now called directly on *pkgs*:

```
# Before (via overlay)
pkgs.buildGoApplication { ... }

# After (identical call, no overlay needed)
pkgs.buildGoApplication { ... }
```

No change to the call site is required — only the overlay that made it
available is removed.

## 5. Simplify devShells with mkGoEnv

Replace explicit *go* and *gomod2nix* CLI listings with a single *mkGoEnv*
derivation. *mkGoEnv* propagates both into the shell automatically, along
with the *go-sync-wrap* hook that regenerates *gomod2nix.toml* after
*go get*, *go mod tidy*, and related commands.

```
# Before
devShells.default = pkgs.mkShell {
  packages = [
    pkgs-master.go
    gomod2nix.packages.${system}.default
    pkgs-master.gopls
    ...
  ];
};

# After
devShells.default = pkgs-master.mkShell {
  packages = [
    (pkgs.mkGoEnv { pwd = ./.; })
    pkgs-master.gopls
    ...
  ];
};
```

# PWD AND SRC RESOLUTION

*buildGoApplication* and *mkGoEnv* both anchor on a *pwd* — the directory
containing *go.mod* (or *go.work*) and *gomod2nix.toml*. Resolution:

. *pwd* given explicitly → used as-is
. *pwd* omitted, *src* given → *pwd* defaults to *src*
  (the single-module case where the Go module lives at the source root)
. *pwd* omitted and *src* omitted → eval-time *throw*

The resolved *pwd* is then validated: if it does not contain a *go.mod*
or *go.work*, *buildGoApplication* / *mkGoEnv* throw at eval time. This
catches the polyglot footgun where a flake passes *src = self* for a
repo whose Go module lives in *./go* — without validation, the failure
surfaces deep inside *mkVendorEnv* with an opaque
*"go.mod: file not found"*.

```
# Single-module: pwd defaults to src
buildGoApplication {
  src = self;
  ...
};

# Polyglot: pwd must point at the Go subdir (substitute the actual
# directory name in your repo — "/go" is the convention some
# amarbel-llc repos use, but the protocol places no constraint on it)
buildGoApplication {
  src = self;
  pwd = self + "/go";
  ...
};
```

When publishing through *mkGoPkgs* (RFC 0001), the *go-pkgs* /
*go-pkgs-test* outputs are themselves *pwd*-shaped — point both *src*
and *pwd* at the output for the self-consumption contract.

# GO VERSION SELECTION

*buildGoApplication* selects the Go toolchain in this order:

. Explicit *go* attribute passed to the call: *buildGoApplication { go = pkgs-master.go_1_26; ... }*
. Version declared in *go.mod* — matched against toolchains available in *pkgs*
. Default *pkgs.go*

For projects that need a specific toolchain (e.g. a release candidate or a
version not yet in the pinned nixpkgs), pass it explicitly:

```
buildGoApplication {
  go = pkgs-master.go_1_26;
  ...
}
```

To avoid two different Go versions silently appearing (one in the build, one
in the devshell), bind the toolchain to a single variable and thread it
through:

```
go = pkgs-master.go_1_26;

tommy-unwrapped = pkgs.buildGoApplication {
  inherit go;
  ...
};

devShells.default = pkgs-master.mkShell {
  packages = [
    (pkgs.mkGoEnv { pwd = ./.; inherit go; })
    ...
  ];
};
```

# GOFLAKEINPUTS

*buildGoApplication* and *mkGoEnv* accept an optional *goFlakeInputs* attribute
that bridges sibling flake-input Go modules into the consumer's module graph
without publishing them or rewriting *go.mod* by hand. This is the supported
way to consume a Go library that lives in a flake input — including polyglot
repos where the Go module is in a subdirectory.

## Value shape

The shorthand form maps a Go module path to a derivation (typically a flake
input's *self*):

```
goFlakeInputs = {
  "code.linenoise.icu/zit/go" = inputs.tap;
};
```

For polyglot repos where the Go module is rooted in a subdirectory of the
flake, use the *{ src, subPath }* form:

```
goFlakeInputs = {
  "code.linenoise.icu/zit/go" = {
    src = inputs.tap;
    subPath = "go";
  };
};
```

## Effect on go.mod

At eval time, *buildGoApplication* and *mkGoEnv* invoke *go mod edit* to
inject a *replace* line per entry, pointing at the absolute */nix/store*
path of the flake input (plus *subPath* when set). *go.mod* on disk is not
modified — the edit happens on a copy used for the build.

A synthetic *require* is injected ONLY for modules the consumer's *go.mod*
does not already require. When the consumer organically requires a bridged
module — the normal case, since that is how the dependency is declared — its
real version stands and NO sentinel is emitted (the *replace* binds to the
existing require). The synthetic *require* uses the sentinel pseudo-version
*vN.0.0-00010101000000-000000000000* (major *N* derived from any */vN* suffix
in the path; *v0* otherwise) and is the fallback for the rare module bridged
without an organic require, where the *replace* would otherwise have nothing
to bind to. So in practice a bridged module almost never carries a sentinel.

## Bridging mode (experimental workspace alternative)

The *require*+*replace*+sentinel mechanism above is the default
(*goFlakeInputsMode = "replace"*). An experimental alternative,
*goFlakeInputsMode = "workspace"*, leaves the consumer *go.mod* untouched
(no synthetic *require*, no sentinel — a */v2*+ producer needs no special
handling, its identity comes from its own *go.mod*) and instead generates the
vendor tree with *go work vendor*:

. a *go.work* is synthesized with the consumer as the sole *use .* member and
  every bridged producer AND external dep expressed as
  *replace <module> => <store path>*;
. *go work vendor* runs in-build (offline, *GOPROXY=off*) so GO itself
  produces *vendor/* + *modules.txt*, owning the MVS / version-skew
  reconciliation that a hand-written *modules.txt* cannot.

Because producers are *replace*d (not *use*d) the consumer's own
*require <producer> <real-version>* line resolves cleanly — a versioned
require for a *use*d member would otherwise fail. This makes the consumer's
real require versions the source of truth, so the mode requires that the
consumer **organically require** each bridged producer (the normal case); a
consumer with no organic require still needs the *replace*-mode sentinel.

This mode is EXPERIMENTAL. Both *buildGoApplication* and *mkGoEnv* honour
*goFlakeInputsMode* — pass the same value to both so build and devshell agree.
*mkGoEnv* exposes the synthesized go.work as *passthru.mergedGoWork* (the
analog of *passthru.mergedGoMod*) for shellHook materialization. Caveats
(amarbel-llc/igloo#39): the vendor derivation is source-dependent (*go work
vendor* reads the import graph) so it caches less than the replace lane; the
go build cache is disabled for bridge builds; polyglot-subdir consumers are
not yet handled (the consumer is *use*d as *.*); and the RFC 0001
merge-primitive revision is pending.

## Effect on gomod2nix.toml

If the flake input ships its own *gomod2nix.toml*, it is unioned with the
consumer's *gomod2nix.toml*. On a module-path conflict the consumer wins;
this lets a consumer pin a transitive dependency without coordinating with
the upstream input. Transitive deps that the input pulls in but the consumer
does not yet track must be added to the consumer's *gomod2nix.toml* (regen
via *go-sync-wrap*) until full FOD-regen lands as a follow-up — see
*LIMITATIONS* below.

For a *subPath* entry the toml is read from the subPath slice; when the
slice has none, the union falls back to the input's root *gomod2nix.toml*
(go.work workspace producers keep one shared lockfile at the workspace
root). A toml at the subPath itself stays authoritative. See
amarbel-llc/igloo#49.

After the union, all keys named in *goFlakeInputs* are stripped from the
merged *mod* table. This prevents two leak vectors that would otherwise
collide with the synthetic *replace*-driven vendor symlinks:

- The consumer's own *gomod2nix.toml* entry for a bridged module (if they
  haven't removed it).
- Any producer flake-input that pins the same module as a transitive dep.

Consumers SHOULD remove their own *gomod2nix.toml* lines for bridged
modules — it keeps the file tidy — but leaving them in is functionally
harmless. See amarbel-llc/nixpkgs#50.

## Coverage warning

At eval time the bridge inspects each bridged producer's *go.mod* and emits
an advisory trace warning when a require that looks private (its host/org
prefix matches a bridged module's) is covered by neither the effective
*goFlakeInputs* map (declared or depth-1 inherited) nor the merged
*gomod2nix.toml*:

```
trace: warning: gomod2nix goFlakeInputs coverage (RFC 0001 duty C,
amarbel-llc/igloo#45): bridged producer <module> requires private
module(s) not covered by the effective goFlakeInputs: <modules>. ...
```

This surfaces a missing bridge (typically a module first appearing two
producers deep, which depth-1 inheritance cannot reach) before the vendor
step fails on it. Advisory only — the build proceeds; fix it by declaring
the named module in *goFlakeInputs* or pinning it in *gomod2nix.toml*.

## mkGoEnv parity

*mkGoEnv* accepts the same *goFlakeInputs* and *goFlakeInputsMode* attributes
and applies the same synthesis (replace or workspace — see *Bridging mode*).
Devshells see the same merged module graph as *nix build*, so
*go build ./...*, *gopls*, and editor tooling resolve cross-flake imports
identically to the production build.

## passthru.mergedGoMod

Both *buildGoApplication* and *mkGoEnv* expose the synthesized *go.mod* as
*passthru.mergedGoMod* — a derivation containing the *go.mod* (and, for
*mkGoEnv*, *go.sum*) with the *replace* lines injected. This is the primary
artifact for debugging a bridge: build it and read it to see exactly what the
merged module graph became — which *replace* lines were emitted, and whether a
bridged module carries a synthetic sentinel *require* or a real version:

```
nix build .#<pkg>.passthru.mergedGoMod && cat result
```

Consumers who want the merged file materialized into their working tree (so
editors and *gopls* read it directly) can wire *mkGoEnv*'s output into a
*shellHook*:

```
let goEnv = pkgs.mkGoEnv { pwd = ./.; inherit goFlakeInputs; };
in pkgs-master.mkShell {
  packages = [ goEnv ];
  shellHook = ''
    cp -f ${goEnv.passthru.mergedGoMod}/go.mod ./go.mod
    chmod u+w ./go.mod
  '';
}
```

## Debugging a failed bridge build

When the merged-*go.mod* step fails (an IFD named *merged-go.mod*), the bridge
annotates the raw *go mod edit* error with context: the offending bridged
module, its provenance (*consumer-declared* vs *inherited* from a producer's
*passthru.goFlakeInputs* at depth 1), the synthesized *require* sentinel, and a
pointer to *passthru.mergedGoMod*. A representative failure:

```
gomod2nix goFlakeInputs bridge: 'go mod edit -replace' failed for bridged module 'example.com/foo/v2'.
  provenance: consumer-declared
  replace target: /nix/store/...-foo-v2-src
  NOTE: if the failing module differs from one you bridged, your own go.mod may carry an
        invalid organic require that 'go mod edit' re-validates while editing this one.
  inspect the merged go.mod:  nix build .#<pkg>.passthru.mergedGoMod && cat result
```

The *NOTE* covers the common mis-attribution case: *go mod edit* re-validates the
whole *go.mod* on every edit, so an invalid organic *require* the consumer wrote
by hand surfaces while editing an unrelated bridged module. See
amarbel-llc/igloo#55.

## Example

*madder* consumes *tap*, whose Go module lives in the *go/* subdirectory of
the *tap* flake:

```
{
  inputs.tap.url = "github:amarbel-llc/tap";

  outputs = { self, nixpkgs, tap, ... }:
    let pkgs = import nixpkgs { inherit system; };
        goFlakeInputs = {
          "code.linenoise.icu/zit/go" = { src = tap; subPath = "go"; };
        };
    in {
      packages.default = pkgs.buildGoApplication {
        pwd = ./.;
        src = self;
        inherit goFlakeInputs;
      };

      devShells.default = pkgs-master.mkShell {
        packages = [ (pkgs.mkGoEnv { pwd = ./.; inherit goFlakeInputs; }) ];
      };
    };
}
```

## Limitations

- *goFlakeInputs* values must be source derivations (a flake's *self*, a
  path, or a fetched src). Pre-built Go binary derivations are not supported
  — only sources are consumed.
- Bridged modules still need a syntactically valid *require* line in
  *go.mod*. The organic *require* (the normal case) is kept untouched and
  shadowed by the *replace*; keep it — it is what makes the merged *go.mod*
  sentinel-free. Its version freezes at bridge-adoption time and goes stale
  as the flake input's rev advances. That staleness is designed and
  harmless: the *replace* wins, and hand-bumping is not possible anyway (a
  private module's newer version has no computable *go.sum* entry). The
  sentinel *require* is injected only for modules with no organic require.
  See RFC 0001 § *Consumer interface*.
- Transitive deps of the flake input that are not in the consumer's
  *gomod2nix.toml* must be added there (regen via *go-sync-wrap* in the
  devshell). Full FOD-driven regeneration of the merged *gomod2nix.toml* is
  tracked as a follow-up.

## See also

For design rationale and the alternatives considered, see
*docs/features/0003-bridge-go-flake-inputs.md*.

# VERSION AND COMMIT INJECTION

*buildGoApplication* automatically injects the following ldflags into every
build:

```
-X main.version=<version>
-X main.commit=<commit>
```

*version* is resolved in this order: the *version* attribute passed to
*buildGoApplication* (an explicit value always wins); else a *version.env*
in the build's module dir (see *version.env auto-read* below); else the
module version from *gomod2nix.toml* if *goPackagePath* is set there; else
the string *"dev"*. *commit* comes from *src.rev* or *src.shortRev* if the
source is a flake input; otherwise it is the string *"unknown"*.

## version.env auto-read

When the build's module dir (*pwd*, which defaults to *src*) contains a
*version.env* declaring a single <PACKAGE>\_VERSION line, *buildGoApplication*
reads it at eval time and uses the value as the version source of truth for
both the derivation *version* attribute and the *-X main.version* ldflag. This
is the eng-versioning(7) convention — a repo gets version embedding for free
just by having a *version.env*, with no per-repo readFile/match boilerplate in
its flake.

```
export PURSE_FIRST_VERSION=0.2.3
```

The *export* keyword is optional. The value is captured as a single
whitespace-delimited token, so a trailing comment or newline is ignored.
Polyglot repos keep one *version.env* per package directory; because the file
is read from *pwd* (the *go.mod* dir of the build), each module picks up its
own package-local file.

This works with the *mkGoPkgs* producer pattern too: *mkGoPkgs* keeps
*version.env* files in its *go-pkgs* / *go-pkgs-test* outputs (see
mkGoPkgs(7) § version.env), so a self-consuming producer whose *pwd* points
at the filtered tree still finds the package-local file — no *extras* entry
or explicit *version* needed.

## Getting a real commit hash

*src = ./.;* is a plain path — it has no *.rev* and commit will always be
*"unknown"*. To bake in the real commit, pass *self* as *src*:

```
outputs = { self, nixpkgs, ... }:
  let
    myapp = pkgs.buildGoApplication {
      src = self;   # self.rev / self.shortRev come from the flake lock
      ...
    };
  in { ... }
```

*self.rev* is only set when the working tree is clean and the flake was
evaluated from a committed ref (e.g. via *nix build* after *git commit*).
*self.shortRev* is the 7-character abbreviation. *buildGoApplication* prefers
*.rev* and falls back to *.shortRev* automatically.

During local development with a dirty tree, *self.rev* is absent — the commit
field falls back to *"unknown"*, which is the intended behaviour.

## Go-side wiring

Declare the variables at package scope in *package main* so the linker can
set them via the *-X* flag:

```
var version = "dev"
var commit  = "unknown"
```

Then surface them in a *version* subcommand:

```
case "version":
    fmt.Printf("myapp %s (%s)\n", version, commit)
```

The variable names must match the ldflag paths exactly: *main.version* and
*main.commit*. If they live in a different package, adjust accordingly (e.g.
*-X mypkg.version*) and update the *ldflags* attribute on *buildGoApplication*.

In development (*nix develop*), the binary is built without the ldflag
injection, so *version* and *commit* will read *"dev"* and *"unknown"*
respectively — which is the intended behaviour.

## Structured -X ldflags (ldflagsX)

For setting additional linker string symbols, *buildGoApplication* accepts an
*ldflagsX* attribute: an attrset mapping a Go symbol path (*importpath.name*)
to a value. Each entry renders to one *-X importpath.name=value* token, sparing
callers the hand-written *-X* string in the *ldflags* list.

```
buildGoApplication {
  ldflagsX = {
    "main.buildDate" = "2026-05-28";
    "main.channel"   = "stable";
  };
}
# adds: -X main.buildDate=2026-05-28 -X main.channel=stable
```

The rendered flags are appended *after* the auto-injected version/commit flags
and the raw *ldflags* list. Because the Go linker's *-X* is last-wins when a
symbol is set twice, *ldflagsX* is authoritative on any overlap.

To make that overlap explicit rather than silent, a key that collides with a
*-X* symbol already set — by the auto-injected *main.version* / *main.commit*,
or by a *-X* entry in the raw *ldflags* list — *throws at eval time*. Pass
*overwriteLdflagsX = true* to allow the override:

```
# Override the auto-injected -X main.version. Without overwriteLdflagsX this
# throws, because main.version is already set by the version/commit injection.
buildGoApplication {
  ldflagsX = { "main.version" = "9.9.9-rc1"; };
  overwriteLdflagsX = true;
}
```

Prefer the *version* attribute (or a *version.env*) over overriding
*main.version* through *ldflagsX* — those keep the derivation *version* attr in
lockstep with the embedded value. *ldflagsX* is for the symbols the version
machinery does not already cover.

Values with embedded spaces are not supported, the same as the raw *ldflags*
list: both are space-joined into a single *-ldflags=* argument and re-split by
the Go linker.

# SEE ALSO

*gomod2nix*(1), *nix-build*(1), *nix*(1)
