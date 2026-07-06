---
status: draft
date: 2026-05-23
promotion-criteria: |
  draft → proposed: at least one producer in this fork publishes the
  dual outputs (`packages.${system}.go-pkgs` and
  `packages.${system}.go-pkgs-test`) per § *Producer interface*; FDR-0003
  and FDR-0004 are thinned to reference this RFC for normative spec.

  proposed → experimental: madder ships the inline-`mkGoPkgs` contract
  test (madder#212) and a consumer builds successfully against both
  outputs (`go-pkgs` for prod, `go-pkgs-test` for test-running).

  experimental → testing: lazy-trees interaction and mkGoEnv parity for
  the filtered outputs are empirically verified; `pkgs.mkGoPkgs` is
  exported from the overlay as the canonical implementation of the
  inline contract (landed via madder#212's adopter validation).

  testing → accepted: at least two producers carry the dual outputs
  for a release cycle without reverting to single-output or bare-`self`
  forms.
---

# RFC 0001 — flake-input-go_mod protocol

## Conventions

The keywords MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD
NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be
interpreted as described in RFC 2119 and RFC 8174 when, and only when,
they appear in all capitals.

## Abstract

The flake-input-go_mod protocol specifies a Nix mechanism for
cross-flake Go module composition. It has two halves that compose
end-to-end: a consumer half (`goFlakeInputs`, an argument to
`buildGoApplication` and `mkGoEnv`) and a producer half (a pair of
flake outputs, `packages.${system}.go-pkgs` for downstream prod
consumption and `packages.${system}.go-pkgs-test` for self-consumption
and test-running consumers, both optionally constructed via
`mkGoPkgs`). The protocol replaces the three-place lockstep —
`go.mod` pseudo-version, `gomod2nix.toml` NAR hash, and `flake.lock`
rev — with a single source of truth: the flake input's rev as
recorded in `flake.lock`. The consumer's merged `go.mod` synthesizes
the appropriate `replace` directive at eval time; the producer
publishes stable, filtered source trees at the conventional
attributes.

## Terminology

For the purposes of this RFC:

- **Producer** — a flake whose output is a Go source tree intended for
  consumption by other flakes. A producer MUST expose both
  `packages.${system}.go-pkgs` (prod shape) and
  `packages.${system}.go-pkgs-test` (test superset).
- **Consumer** — a flake that depends on one or more producers' Go
  source trees through Nix flake inputs. A consumer MUST declare those
  dependencies through `goFlakeInputs`.
- **Bridge** — the eval-time merge step that combines the consumer's
  organic `go.mod` with synthetic `replace` directives derived from
  `goFlakeInputs`. The bridge implementation lives in this fork's
  `buildGoApplication` and `mkGoEnv`.
- **Middleware** — a function `src -> src` (derivation to derivation)
  that transforms a Go source tree. The middleware-aware producer-side
  helper is deferred to a future revision; see § *Producers with
  codegen (deferred)*.
- **`goFlakeInputs`** — the consumer-side bridge argument. An attrset
  mapping Go module paths to flake-input derivations (or `{ src;
  subPath; }` records). Specified normatively in §
  *Consumer interface: `goFlakeInputs`*.
- **`go-pkgs`** — the conventional flake output attribute name for a
  producer's Go source tree (prod shape; excludes `*_test.go` and
  `testdata/**`). Specified normatively in
  § *Producer interface: dual `go-pkgs` outputs and `mkGoPkgs`*.
- **`go-pkgs-test`** — the test-superset companion of `go-pkgs`. Same
  prod surface plus `*_test.go` and `testdata/**`. Specified
  normatively in § *Producer interface*.
- **`gomod.nix`** — the conventional colocation file that is the
  Nix interface to `go.mod`. Carries the producer's `mkGoPkgs`
  arguments and/or the consumer's `goFlakeInputs` attrset; mixed
  flakes (producer + consumer) carry both. Specified normatively in
  § *The `gomod.nix` convention*.

## Protocol overview

The protocol has two complementary halves. On the producer side, a
flake exposes its Go source tree as a pair of derivations — one
prod-shape (`packages.${system}.go-pkgs`, excludes `*_test.go` and
`testdata/**`) and one test-superset (`packages.${system}.go-pkgs-test`,
includes both). On the consumer side, a flake declares which producers
it depends on by passing `goFlakeInputs` to `buildGoApplication` and
`mkGoEnv`; the bridge merges synthetic `replace` directives into the
consumer's `go.mod` at Nix eval time, pointing each declared Go module
path at the chosen producer output (typically `go-pkgs`; consumers
that need to run the producer's tests bridge against `go-pkgs-test`).

The protocol exists to close the lockstep-drift class. Without the
bridge, cross-repo Go composition in this fork requires editing three
places in lockstep: `go.mod`'s pseudo-version, `gomod2nix.toml`'s NAR
hash, and `flake.lock`'s rev of the sibling-module input. When any of
these drifts, the build still succeeds — each layer is internally
consistent — but the binary runs against the wrong version of the
sibling. The bridge collapses the lockstep so that only the flake
input rev matters: the merged `go.mod`'s `replace` points at the new
store path automatically, and `gomod2nix.toml` only tracks the
*organic* (non-bridged) surface.

## Consumer interface: `goFlakeInputs`

Implementations MUST accept a `goFlakeInputs` argument on
`buildGoApplication` and `mkGoEnv`. The argument is an attrset mapping
Go module paths to source derivations.

### Schema

```nix
goFlakeInputs :: AttrSet (Derivation | { src :: Derivation; subPath :: String })
```

Each entry's key MUST be a fully qualified Go module path (e.g.
`github.com/amarbel-llc/dodder`). Each entry's value MUST be either:

- a derivation whose output is a Go module source tree rooted at the
  derivation's top level; or
- a record `{ src = <derivation>; subPath = <string>; }`, where `src`
  is such a derivation and `subPath` is a directory within `src` that
  contains the Go module's `go.mod`.

Implementations MUST NOT accept other value shapes (e.g. raw store
paths, URLs, or fetcher specifications); callers wanting non-flake
sources MUST wrap them in a derivation first.

### Merge primitive

Implementations MUST merge `goFlakeInputs` into the consumer's `go.mod`
by injecting a `replace` directive per entry, semantically equivalent
to `go mod edit -replace=<module>=<store-path>`. The merge MUST happen
at Nix eval time, in parallel to the organic `goMod.replace` entries
that `mkVendorEnv` already processes. Synthetic entries MUST take
priority over any organic `require` pseudo-version for the same module
path: the organic `require` line becomes vestigial and only needs to
remain syntactically present so Go's parser is satisfied.

Implementations MUST NOT require that the consumer's source filesystem
contain a placeholder directory matching the replace target. Synthetic
entries are derivation references at eval time; the value of an entry
is passed through to the merged `go.mod` as the relevant store path
directly, not reconstructed via `pwd + "/${value.path}"`. (This is the
concrete blocker the FDR-0003 POC identified at
`pkgs/build-support/gomod2nix/default.nix:198-205`; the protocol
forbids that shape.)

### Inline declaration

`goFlakeInputs` MUST be passed inline as a builder argument. The
protocol does not define any out-of-band declaration mechanism (no
separate `flake-go-inputs.toml` manifest, no environment-variable
escape hatch). The single source of truth for synthetic versions is
the flake input's rev as recorded in `flake.lock`.

### `mkGoEnv` parity

Implementations MUST apply identical merge semantics in `mkGoEnv` as
in `buildGoApplication`. A consumer's `nix develop` shell MUST see the
same module graph as `nix build`. Implementing only the build-side
silently reintroduces lockstep drift through the back door: editors
and language servers in the devshell see one set of replace targets
while the build sees another.

### Out-of-Nix builds

The protocol does NOT support `go build` invocations outside Nix. A
consumer MUST run Go work through `nix develop` or `nix build`. The
merged `go.mod` is materialized into the build sandbox at
`buildGoApplication` time and is not written back to the consumer's
working tree. Editor and language-server workflows that parse `go.mod`
directly may need the merged form materialized into the workspace;
that materialization step is a non-normative follow-up.

### Example

```nix
{ pkgs, inputs, ... }:
let
  madder = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    subPackages = [ "cmd/madder" ];
    modules = ./gomod2nix.toml;
    goFlakeInputs = {
      "github.com/amarbel-llc/dodder" = inputs.dodder;
      "github.com/amarbel-llc/tap/go" = {
        src = inputs.tap.packages.${pkgs.system}.go-pkgs;
        subPath = "go";
      };
    };
  };
in {
  packages.default = madder;
}
```

The consumer's `gomod2nix.toml` SHOULD NOT carry entries for modules
declared in `goFlakeInputs` — leaving them in is cosmetically untidy
but functionally harmless (the bridge strips them at merge time).
`go.mod` retains the `require` line (Go's parser needs *some*
version). Two cases:

- **Organic require (the normal case).** The consumer's `go.mod`
  already requires the bridged module at a real version — that is how
  the dependency is declared in the first place. The bridge keeps the
  organic version untouched and only injects the `replace`
  (amarbel-llc/igloo#39, commit `82f3d8e`). No sentinel appears.
- **No organic require (rare).** The bridge injects a synthetic
  `require` with a sentinel pseudo-version such as
  `v0.0.0-00010101000000-000000000000`. The sentinel's major MUST
  match any major-version suffix in the module path: a path ending
  `/vN` (N ≥ 2) requires `vN.0.0-00010101000000-000000000000`, since
  `go mod edit -require` rejects a require whose major disagrees with
  the path's declared major (`should be vN, not v0`). See
  amarbel-llc/igloo#38.

In both cases the require is immediately shadowed by the local
`replace`; the version text is decoration.

**Staleness of the organic version is the designed state.** The
organic require's version (typically a pseudo-version or tag frozen at
bridge-adoption time) goes stale as the flake input's rev advances in
`flake.lock`. This is harmless by construction — the `replace` wins,
and the flake input's rev remains the single source of truth. It is
also **not fixable**: bumping the pseudo-version to track the flake
rev would require a matching `go.sum` entry, which `go mod tidy`
cannot compute for a private, proxy-unreachable module. Consumers
MUST NOT hand-bump these versions, MUST NOT build self-healing lanes
that rewrite them, and SHOULD exclude bridged modules from any
"outdated dependency" tooling. The version's only remaining audiences
are Go's parser and out-of-Nix tooling that the protocol already
declares unsupported (§ *Out-of-Nix builds*).

Implementations MUST remove all keys named in `goFlakeInputs` from
the merged `modulesStruct.mod` table before passing it to the vendor
materializer. Without this step, an entry for module X from either
the consumer's own `gomod2nix.toml` OR any producer flake-input's
transitive pin would cause the vendor builder to pre-populate
`vendor/<X>` from a fetched NAR, colliding with the synthetic
`replace`-driven symlink the bridge wires. See
amarbel-llc/nixpkgs#50.

## Producer interface: dual `go-pkgs` outputs and `mkGoPkgs`

### Flake output naming

A Go-source-producing flake MUST expose **two** flake outputs that
differ only in whether the test surface is included:

```
packages.${system}.go-pkgs       # prod shape
packages.${system}.go-pkgs-test  # superset: prod + test surface
```

- `go-pkgs` MUST contain `*.go` (excluding `*_test.go`), `go.mod`,
  `go.sum`, and `gomod2nix.toml`. It MUST NOT contain `*_test.go`
  files or `testdata/**` directories. This is the "prod shape" that
  downstream consumers bridge against when they only compile non-test
  code.
- `go-pkgs-test` MUST be the **superset** of `go-pkgs`: same prod
  surface, plus `*_test.go`, plus `testdata/**`. This is the shape
  that supports running the producer's tests against the bridged
  tree — including self-consumption, where the producer's own
  `checkPhase` evaluates `go test ./...` against the published source.

Both values MUST be derivations (or paths coercible to one) whose
output is a directory containing a Go module: `go.mod` at the root
(or at a subdirectory addressable via the consumer's `subPath`) and
the importable packages of that module.

Consumers reference the appropriate variant when wiring
`goFlakeInputs`:

```nix
goFlakeInputs = {
  # prod consumer — most callers
  "github.com/amarbel-llc/purse-first" =
    inputs.purse-first.packages.${system}.go-pkgs;

  # test-runner consumer — wants the producer's tests too
  "github.com/amarbel-llc/tap/go" = {
    src = inputs.tap.packages.${system}.go-pkgs-test;
    subPath = "go";
  };
};
```

Downstream consumers SHOULD bridge against `go-pkgs` by default. They
MUST bridge against `go-pkgs-test` only when they need the producer's
test files materialized inside the bridged source tree (e.g. to run
`go test` against the producer's package, or because the consumer
needs a fixture under `testdata/`).

A producer MAY expose additional Go output variants under other
attribute names (e.g. `go-pkgs-server`, `go-pkgs-cmd`). Variant names
beyond `go-pkgs` and `go-pkgs-test` are not standardized by this
protocol; consumers wanting them MUST reference them explicitly via
the `{ src = ...; }` record form on the `goFlakeInputs` entry.

### Why the split

`go-pkgs` and `go-pkgs-test` cannot collapse to a single output
because the two audiences have opposed requirements:

- A unified-tight default (drop `*_test.go` + `testdata/**`) breaks
  self-consumption: a producer building itself from its own
  `go-pkgs` fails the moment `go test ./...` tries to load a fixture.
- A unified-loose default (keep `*_test.go` + `testdata/**`) bloats
  every downstream prod consumer's input closure with test fixtures
  and `_test.go` files they never compile, increasing cache
  invalidation and store-size pressure.

See amarbel-llc/nixpkgs#46 for the motivating discussion.

### Producer `src` scoping

Two scoping shapes exist in the fleet for repos whose Go module does
not live at the repository root: scope `mkGoPkgs`'s `src` to the
module directory (`src = self + "/go"`; consumers map the module path
to `go-pkgs` with no `subPath`), or filter the full repo
(`src = self`; every consumer passes `subPath = "go"`).

**A single-Go-module producer SHOULD scope `src` to the module
directory.** Rationale:

- **Tightest cache key.** The filtered tree can only change when the
  module directory changes. A full-repo filter additionally admits
  `*.go`, `go.mod`, `go.sum`, and `gomod2nix.toml` files from anywhere
  else in the repo (a stray tool script in a sibling language tree
  leaks in), and preserves the whole repo's empty directory skeleton
  (§ *Limitations*, empty directories).
- **Simpler consumer wiring.** No `subPath` to coordinate; the
  `goFlakeInputs` entry is a bare derivation. `subPath` mistakes are a
  consumer-side failure class that scoping eliminates.
- **Direct self-consumption.** `go.mod` sits at the filtered tree's
  root, so `src`/`pwd` point at the output with no path arithmetic.

Two obligations come with scoping:

- Pass an explicit `name` (`"<repo>-go"`): the go.mod inference on a
  module path ending `/go` yields the undiagnostic store-path prefix
  `"go"`. See amarbel-llc/nixpkgs#49.
- Keep a `version.env` **inside** the module directory if the producer
  relies on `buildGoApplication`'s version auto-read; a repo-root
  `version.env` is outside the scoped tree.

A repo publishing **multiple** Go modules from one flake is the case
full-repo-filtered + consumer `subPath` exists for (e.g. purse-first's
`libs/dewey`): one output pair serves all modules and each consumer
slices the module it wants. Existing single-module producers that ship
full-repo-filtered outputs (tap, crap) MAY migrate to scoped `src`;
migration changes the consumer contract (consumers drop their
`subPath`), so it requires a coordinated consumer update.

### Producers ship `gomod2nix.toml`

A producer SHOULD ship a fresh `gomod2nix.toml` at the Go module root
inside `go-pkgs` (the default keep-set preserves it; the obligation is
that it exist and be current with `go.mod`).

The consumer-side bridge unions each flake input's `gomod2nix.toml`
into the consumer's own (consumer wins on conflict) to obtain NAR
pins for the producer's **external** transitive deps. A producer that
ships no `gomod2nix.toml` contributes an empty pin set — tolerated
mechanically, but every consumer must then carry pins for the
producer's externals itself. That reintroduces a lockstep class this
protocol exists to close: consumers cannot regenerate pins for a
producer-only external (their out-of-Nix `gomod2nix generate` cannot
resolve the private producer module to walk its requires), so a
producer adding an external dep breaks each consumer's build with a
missing-module error and cross-repo triage.

Producers whose own builds do not consume the file (e.g. binaries
built with a `vendorHash`-based builder) SHOULD gate its freshness —
either by self-consuming through `buildGoApplication` with
`modules = ./gomod2nix.toml` (see § *Self-consumption SHOULD*, the
RECOMMENDED shape, which makes staleness a build failure) or by a
conformist lane that runs `gomod2nix generate` and fails on diff.

### `mkGoPkgs` helper

The fork's overlay SHOULD expose `pkgs.mkGoPkgs` as the canonical
producer-side helper that emits both outputs from a single call:

```nix
mkGoPkgs = {
  src,
  extras ? [ ],
  testExtras ? [ ],
}: {
  go-pkgs       :: Derivation;  # prod shape
  go-pkgs-test  :: Derivation;  # superset of go-pkgs
}
```

> **Implementation status:** `pkgs.mkGoPkgs` is implemented and
> exported from the fork's overlay
> (`pkgs/build-support/gomod2nix/mk-go-pkgs.nix`).
> [madder#212](https://github.com/amarbel-llc/madder/issues/212)
> shipped the **inline contract test** — an open-coded equivalent of
> the helper inside madder's `flake.nix` that produces the same two
> outputs and self-consumes them through `buildGoApplication`'s
> `checkPhase`. Madder's adopter report (comments on
> [nixpkgs#46](https://github.com/amarbel-llc/nixpkgs/issues/46))
> de-risked the helper's design before extraction. Madder's flake
> will collapse to the helper call as the in-tree implementation
> propagates.

Arguments:

- `src` — a derivation or path containing the Go source tree.
  REQUIRED.
- `extras` — OPTIONAL list of POSIX extended-regex strings added to
  the keep-set of **both** outputs. Use for files relevant to both
  prod and test builds (e.g. embedded asset directories, top-level
  config files referenced by `//go:embed`).
- `testExtras` — OPTIONAL list of POSIX extended-regex strings added
  only to `go-pkgs-test`. Use for fixtures that live outside the
  default `testdata/**` convention.

Outputs:

- `go-pkgs` — derivation whose tree matches `*.go` (excluding
  `*_test.go`) plus the module files (`go.mod`, `go.sum`,
  `gomod2nix.toml`) plus `extras`.
- `go-pkgs-test` — derivation whose tree matches the union of the
  `go-pkgs` keep-set, `*_test.go`, `testdata/**` (matched as
  `^testdata/.*` and `.*/testdata/.*`), and `testExtras`.

Both outputs MUST be real derivations (`lib.isDerivation` true) so
that they satisfy `nix flake check`'s schema gate (see
amarbel-llc/nixpkgs#44 for the gate the protocol's earlier
single-output versions tripped on).

The earlier middleware-aware variant (a `middlewares` argument that
composed `src -> src` transformations) is deferred to a separate
future helper (provisionally `mkGoPkgsWithMiddleware`). See
§ *Producers with codegen (deferred)*.

`mkGoPkgs` MUST NOT slice the tree by any caller-side `subPath` arg.
The two outputs always cover the full `src` tree; consumers control
per-consumer slicing through the `subPath` attribute on
`goFlakeInputs` entries.

`mkGoPkgs` attaches `passthru.goFlakeInputs` to both outputs when the
caller passes a non-empty `goFlakeInputs` argument. The attribute is
omitted entirely when the producer has no cross-flake deps so
consumers can probe `passthru ? goFlakeInputs` unambiguously. See
§ *Multi-producer closures: `follows` + passthru inheritance* for how
the consumer-side bridge unions these declarations at depth-1.

### Producers without middleware

A producer that ships hand-written Go with no codegen SHOULD publish
both outputs via `mkGoPkgs`:

```nix
inherit (pkgs.mkGoPkgs { src = self; }) go-pkgs go-pkgs-test;

packages.${system} = {
  inherit go-pkgs go-pkgs-test;
};
```

### Self-consumption SHOULD

A producer SHOULD point its own `buildGoApplication` `src` (and
`pwd`) at its published `go-pkgs-test` output:

```nix
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
      # checkPhase runs `go test ./...` against the filtered tree;
      # this is the contract test that catches publish-but-broken
      # cases for the producer's own consumers.
    };
  };
}
```

This makes the producer's own `checkPhase` the contract test for the
two outputs. A producer that does not self-consume can publish a
`go-pkgs-test` that subtly fails downstream (missing a fixture, an
embed asset, a workspace file) and never notice. Self-consumption
turns "the published tree is valid" from a documentation claim into a
build invariant. See madder#212 for the originating adopter
experience.

The SHOULD is about **what** is consumed, not **which builder**
consumes it. The contract is: *the producer's own merge gate builds —
and, where the gate runs tests at all, tests — from the published
`go-pkgs-test` tree rather than from the raw worktree.* In descending
order of coverage:

1. **`buildGoApplication` with `src`/`pwd` = `go-pkgs-test` and
   `modules = ./gomod2nix.toml` (RECOMMENDED).** One derivation gates
   three things at once: filter completeness, `gomod2nix.toml`
   freshness, and the exact vendor machinery consumers will run the
   published tree through.
2. **Any other Nix Go builder pointed at `go-pkgs-test`** (e.g. an
   existing `vendorHash`-based `buildGoModule` for the repo's
   binaries) — acceptable. With its `checkPhase` enabled,
   `go test ./...` walks the whole module and the coverage matches
   shape 1 minus the gomod2nix-machinery leg (a stale or wrong
   `gomod2nix.toml` passes this gate but breaks consumers — pair with
   the freshness lane from § *Producers ship `gomod2nix.toml`*).
   Build-only (no check) covers just the binaries' import graph and
   the module files.
3. **No Nix Go build in the repo at all** — the fallback floor is a
   check-only derivation in the producer's gate that runs
   `go vet ./...` against `go-pkgs-test`. `go vet` compiles and
   type-checks every package *including test files*, so it catches the
   missing-fixture/missing-embed/missing-child-`go.mod` filter class
   without being a test run. Note `go vet` needs the module's
   dependency graph, so in Nix this is in practice a `doCheck`-only
   builder invocation with its outputs discarded — the "no Go build"
   posture buys less than it appears to, which is why this is the
   floor and not the recommendation.

A producer that adopts none of these ships filter regressions that
surface first in a **consumer's** merge gate, as cross-repo triage.
That failure mode is the thing this section exists to prevent; gate
maintainers accepting shape 3 (or less) accept that trade
explicitly.

The `modules` argument is a producer-discretion call: pointing at
`./gomod2nix.toml` (worktree-relative) evaluates faster at
flake-eval time; pointing at `"${goPkgs.go-pkgs-test}/gomod2nix.toml"`
(filtered-tree-relative) is a stronger contract because drift
between the worktree's lockfile and the filter's view becomes
structurally impossible. Producers MAY pick either.

Other forms that producers may be tempted to use for the prod output
have hidden gotchas:

- `packages.${system}.go-pkgs = self;` — `self` is a flake attrset.
  The flake-output schema rejects it ("expected ... a derivation or
  path but found a set"). See amarbel-llc/nixpkgs#38.
- `packages.${system}.go-pkgs = self.outPath;` — passes `nix build`
  but fails `nix flake check` (which requires `lib.isDerivation`).
  See amarbel-llc/nixpkgs#44.
- `packages.${system}.go-pkgs = ./.;` — same issue as `self.outPath`.

### Producers with codegen (deferred)

A producer that runs codegen (e.g. via a future
`pkgs.dagnabitExportMiddleware`) or otherwise transforms its source
through a middleware pipeline is **out of scope** for this revision
of the protocol. The earlier middleware-aware `mkGoPkgs` interface
moves to a separate future helper (provisionally
`mkGoPkgsWithMiddleware`); when that helper lands it will produce the
same dual-output shape and accept a `middlewares` list of `src -> src`
transformations applied left-to-right via `foldl'`.

Producers needing codegen today MUST inline the middleware steps in
their flake and publish the resulting derivations directly as
`go-pkgs` and `go-pkgs-test`. See FDR-0004's `dagnabitExportMiddleware`
sketch for the shape the future helper is expected to take.

## Source filtering: `goSourceFilter`

### Rationale

A producer that uses bare `self` as its `packages.${system}.go-pkgs`
value cache-couples every downstream consumer's build closure to
every file in the producer's repository — including README edits,
scdoc man-page changes, justfile recipes, `.github/` workflow tweaks,
and any other non-Go file. Each such edit changes the producer's
store path, invalidates the consumer's vendor FOD, and forces a
rebuild that has no semantic relationship to the change.

A producer SHOULD scope its `go-pkgs` output to Go-relevant files.
Producers that already maintain a `cleanSourceWith`-style filter (for
their own builds) SHOULD reuse that filter for `go-pkgs`. Producers
without a pre-existing filter MAY use `pkgs.goSourceFilter` for the
common case.

### `goSourceFilter` interface

```nix
goSourceFilter :: { src :: Path; extras ? [ String ]; } -> Source
```

Arguments:

- `src` — REQUIRED. A path or derivation containing the Go source
  tree.
- `extras` — OPTIONAL. A list of POSIX extended-regex strings (default:
  empty) that augment the default keep-set.

`goSourceFilter` MUST produce a **derivation** (i.e. `lib.isDerivation`
true) whose output is the filtered tree of `src`. Directories MUST be
always traversed and regex patterns MUST be matched against the
source-tree-relative path of each regular file.

The reference implementation builds the filter with `builtins.path`
(which both `lib.cleanSourceWith` and `lib.sources.sourceByRegex`
delegate to) and then wraps the result in a `runCommand` that copies
the filtered tree into `$out`. Returning a real derivation is required
because `nix flake check` is strictly stronger than `nix build`: it
runs `isDerivation` on every `packages.<system>.<name>` value. A bare
`lib.cleanSourceWith` set fails both gates
(see amarbel-llc/nixpkgs#38); a bare `builtins.path` passes
`nix build` but fails `nix flake check` (see amarbel-llc/nixpkgs#44).
The `runCommand`-wrapped derivation passes both, so producers MAY
use `pkgs.goSourceFilter { src = self; }` directly as the value of a
`packages.<system>.<name>` flake output. Note that doing so satisfies
the schema gates but NOT the dual-output convention from § *Producer
interface*: a compliant producer needs `mkGoPkgs` (or the open-coded
equivalent) to publish both `go-pkgs` and `go-pkgs-test`.
`goSourceFilter` is the building block; `mkGoPkgs` is the canonical
entry point.

### Default keep-set

`goSourceFilter` MUST keep, at minimum, the following files (matched
against the source-tree-relative path of each file):

- `.*\.go$` — any Go source file.
- `(.*/)?go\.mod$` — the module manifest, at the source root or at
  any sub-module under a `go.work` `use` directive.
- `(.*/)?go\.sum$` — the module checksum file, at any module root.
- `^go\.work$` — the workspace manifest (matches `go help workspace`'s
  canonical file list).
- `^go\.work\.sum$` — the workspace checksum file.
- `(.*/)?gomod2nix\.toml$` — the `gomod2nix` lockfile, at any module
  root.

Module files (`go.mod`, `go.sum`, `gomod2nix.toml`) match by basename
anywhere in the tree so `go.work`-based workspaces' child module
files survive the filter. See amarbel-llc/nixpkgs#48.

Workspace files (`go.work`, `go.work.sum`) only ever live at the
workspace root by Go's design and stay root-anchored. Single-module
producers are unaffected — these regexes match nothing in trees that
have no `go.work` file. See amarbel-llc/nixpkgs#45.

All other files MUST be dropped unless matched by an entry in
`extras`.

### `extras` semantics

`extras` entries MUST be POSIX extended-regex strings, matched against
the source-tree-relative path of each file (consistent with
`builtins.match` semantics). They are
NOT glob patterns; the nixpkgs stdlib does not ship glob matching, and
`goSourceFilter` does not introduce a new syntax on top.

Examples:

```nix
# Keep the doc/ subtree
extras = [ "^doc/.*" ];

# Keep a single root file
extras = [ "^VERSION$" ];

# Keep all *.tmpl files
extras = [ ".*\\.tmpl$" ];

# Combine
extras = [ "^doc/.*" "^VERSION$" ".*\\.tmpl$" ];
```

### Store-path naming

`goSourceFilter` MUST preserve `src.name`. The resulting store path is
named identically to the input `src`. Producers that want a more
diagnostic name (e.g. `${src.name}-go-source`) MAY rewrap the result
with another `runCommand` so the renamed output is also a derivation
(and thus passes `nix flake check`):

```nix
pkgs.runCommand "${src.name}-go-source" { } ''
  cp -r ${pkgs.goSourceFilter { inherit src; }} $out
''
```

### `goSourceFilterMiddleware`

The fork's overlay SHOULD also expose `pkgs.goSourceFilterMiddleware`,
a 1-line `src -> src` wrapper around `goSourceFilter`:

```nix
goSourceFilterMiddleware = src: goSourceFilter { inherit src; };
```

It exists so the filter composes naturally into the
`mkGoPkgs.middlewares` pipeline without forcing producers to write the
closure themselves:

```nix
packages.${system}.go-pkgs = pkgs.mkGoPkgs {
  src = self;
  middlewares = [
    pkgs.goSourceFilterMiddleware
    # ... other middlewares ...
  ];
};
```

## The `gomod.nix` convention

`gomod.nix` is the **Nix interface to `go.mod`** — a single colocation
file that captures the flake's Go-side surface in Nix terms.
Symmetric with `go.mod`'s role on the Go side: every Go-flake that
participates in this protocol SHOULD lift its Nix-Go wiring into
`gomod.nix` (or `go/gomod.nix` for polyglot repos), and `flake.nix`
imports it.

A `gomod.nix` file MAY contain either or both of:

- **Producer half** — the `mkGoPkgs` call arguments (`src`, `extras`,
  `testExtras`) for the flake's own Go-source publication.
- **Consumer half** — the `goFlakeInputs` attrset for cross-flake Go
  module dependencies.

A pure-producer flake's `gomod.nix` carries only the producer block;
a pure-consumer's carries only the consumer block; a mixed flake
(producer of its own Go source AND consumer of sibling-flake Go
modules — most adopters in this fork) carries both.

`gomod.nix` MUST be a function from its dependencies (`pkgs`, `src`,
flake inputs, `system`) to either a single attrset (single-half) or
an attrset containing `goPkgs` / `goFlakeInputs` / both. The file
MUST NOT depend on state outside its arguments; it MUST be importable
from any `buildGoApplication`, `mkGoEnv`, or `mkGoPkgs` call in the
same flake.

### Producer-half shape

```nix
# gomod.nix — pure-producer flake
{ pkgs, src }:
pkgs.mkGoPkgs {
  inherit src;
  extras = [ ];        # optional: extras for both outputs
  testExtras = [ ];    # optional: extras only for go-pkgs-test
}
```

Then in `flake.nix`:

```nix
let
  goPkgs = import ./gomod.nix { inherit pkgs; src = self; };
in {
  packages.${system} = {
    inherit (goPkgs) go-pkgs go-pkgs-test;
    # Self-consumption SHOULD: build against own go-pkgs-test
    default = pkgs.buildGoApplication {
      src = goPkgs.go-pkgs-test;
      pwd = goPkgs.go-pkgs-test;
      modules = ./gomod2nix.toml;
    };
  };
}
```

For polyglot repos with Go under `go/`, the file lives at
`go/gomod.nix` and `pwd` / `src` pass `self + "/go"`.

### Consumer-half shape

```nix
# gomod.nix — pure-consumer flake (or polyglot's go/gomod.nix)
{ tap, tommy, system }: {
  "github.com/amarbel-llc/tap/go" = {
    src = tap.packages.${system}.go-pkgs;
    subPath = "go";
  };
  "github.com/amarbel-llc/tommy" = {
    src = tommy.packages.${system}.go-pkgs;
  };
}
```

Single-dep bridges MAY remain inline in the `buildGoApplication`
call; the colocation convention exists to reduce duplication and
surface drift, both of which only matter at multi-dep scale.

Call sites in `flake.nix`:

```nix
let
  goFlakeInputs = import ./go/gomod.nix {
    inherit (inputs) tap tommy;
    inherit system;
  };
in {
  packages.${system}.default = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    modules = ./gomod2nix.toml;
    inherit goFlakeInputs;
  };

  devShells.${system}.default = pkgs.mkShell {
    inputsFrom = [
      (pkgs.mkGoEnv {
        pwd = ./.;
        inherit goFlakeInputs;
      })
    ];
  };
}
```

### Mixed shape (producer + consumer)

A flake that is both a producer (publishes its own `go-pkgs`) and a
consumer (bridges sibling flakes' Go modules) puts both halves in one
`gomod.nix`:

```nix
# gomod.nix — mixed flake (e.g. madder, dodder, maneater)
{ pkgs, src, tap, tommy, purse-first, system }: {
  goPkgs = pkgs.mkGoPkgs {
    inherit src;
    extras = [ ];
    testExtras = [ ];
  };

  goFlakeInputs = {
    "github.com/amarbel-llc/tap/go" = {
      src = tap.packages.${system}.go-pkgs;
      subPath = "go";
    };
    "github.com/amarbel-llc/tommy" = {
      src = tommy.packages.${system}.go-pkgs;
    };
    "github.com/amarbel-llc/purse-first/libs/go-mcp" = {
      src = purse-first.packages.${system}.go-pkgs;
      subPath = "libs/go-mcp";
    };
  };
}
```

Then in `flake.nix`:

```nix
let
  gomod = import ./gomod.nix {
    inherit pkgs system;
    src = self;
    inherit (inputs) tap tommy purse-first;
  };
in {
  packages.${system} = {
    inherit (gomod.goPkgs) go-pkgs go-pkgs-test;
    default = pkgs.buildGoApplication {
      src = gomod.goPkgs.go-pkgs-test;
      pwd = gomod.goPkgs.go-pkgs-test;
      modules = ./gomod2nix.toml;
      inherit (gomod) goFlakeInputs;
    };
  };

  devShells.${system}.default = pkgs.mkShell {
    inputsFrom = [
      (pkgs.mkGoEnv {
        pwd = ./.;
        inherit (gomod) goFlakeInputs;
      })
    ];
  };
}
```

### Threading

Every `buildGoApplication` and `mkGoEnv` call that consumes the
flake's `gomod2nix.toml` MUST receive the same `goFlakeInputs`
value. The recommended idiom is `inherit (gomod) goFlakeInputs;` at
each call site, with the single binding shared from the top-level
`let`. Missing call sites silently resurrect lockstep drift: the
build sees one set of replace targets, the devshell sees another.
See [amarbel-llc/nixpkgs#41](https://github.com/amarbel-llc/nixpkgs/issues/41)
for proposed lint coverage.

### Why this convention exists

Four reasons motivate the `gomod.nix` colocation pattern:

1. **Mirror of `go.mod`.** Every Go-flake that participates in this
   protocol has a single Nix-side file that mirrors `go.mod`'s
   semantics: what this flake publishes (producer) and what it
   depends on through Nix (consumer). The mental model is uniform
   across producers, consumers, and mixed flakes.
2. **Discoverability.** `cat gomod.nix` answers both "which sibling
   Go modules does this flake bridge?" and "how does this flake
   filter its own Go source?" without scanning the entire
   `flake.nix`.
3. **Drift surface.** With every `buildGoApplication` and `mkGoEnv`
   call importing the same `gomod.nix` binding, divergence between
   call sites becomes a single `grep` target: any call lacking
   `inherit (gomod) goFlakeInputs;` is the bug.
4. **Symmetric file naming.** Producers, consumers, and mixed flakes
   all use the same filename. Adopters don't have to think about
   what file to look in based on which half they're working on.

## Multi-producer closures: `follows` + passthru inheritance

When a consumer depends on multiple flake inputs that themselves share
a transitive Go dependency, two mechanisms keep the resulting closure
coherent: Nix flake `follows` for input alignment, and depth-1
`passthru.goFlakeInputs` inheritance for declaration reuse.

### Shared transitive deps: align with `follows`

A consumer that pulls both `tap` and `dewey` as flake inputs — and
where `tap` itself depends on `dewey` — SHOULD anchor `tap`'s view of
dewey to the consumer's own input via `follows`:

```nix
inputs = {
  dewey.url = "github:amarbel-llc/purse-first/libs/dewey";
  tap = {
    url = "github:amarbel-llc/tap";
    inputs.dewey.follows = "dewey";   # tap's dewey is now madder's dewey
  };
};
```

`follows` is Nix's existing flake-level alignment mechanism; the
bridge MUST NOT replicate or enforce version policy on top of it.
Go's module-path encoding (`X` vs `X/v2`) already makes cross-major
substitution structurally impossible, and within-cohort version
mismatches surface as ordinary compile errors via `-mod=vendor`. The
build is the authoritative check; `follows` ensures the inputs align
before the build even runs.

### Producer-side passthru inheritance

A producer flake that itself uses `goFlakeInputs` to source its Go
modules MAY expose those declarations to consumers via
`passthru.goFlakeInputs` on its `go-pkgs` (and `go-pkgs-test`)
derivations. When both outputs are published, the producer SHOULD
attach the same `passthru.goFlakeInputs` to both so that consumers
inheriting through either output see the same declarations.

> **Implementation status:** `mkGoPkgs` accepts a `goFlakeInputs`
> argument that attaches `passthru.goFlakeInputs` to both outputs;
> the consumer-side bridge in `internals.nix` unions inherited
> entries at depth-1 via `inheritedGoFlakeInputs`. The advisory
> coverage warning (eval-time check that each bridged producer's
> `go.mod` requires are covered by the consumer's merged map) ships
> as `goFlakeInputsCoverageGaps`, surfaced by `mkMergedView` as a
> trace warning
> ([amarbel-llc/igloo#45](https://github.com/amarbel-llc/igloo/issues/45)).

Implementations of the bridge MUST read each direct flake-input's
`passthru.goFlakeInputs` and union the entries into the consumer's
merged map at depth-1. Consumer-declared entries MUST win on conflict:
when a Go module path appears both in the consumer's own
`goFlakeInputs` and in an inherited passthru, the consumer's entry
takes priority.

When combined with `follows` alignment above, inherited entries
naturally resolve to the same flake inputs the consumer already has,
with no extra declaration required:

```nix
# producer (e.g. tap) — pseudo-code, see Implementation status
# note below for current attachment mechanism.
packages.${system} = pkgs.mkGoPkgs { src = self; };
# both go-pkgs and go-pkgs-test carry passthru.goFlakeInputs =
# { "github.com/amarbel-llc/purse-first/libs/dewey" = inputs.dewey; }

# consumer (e.g. madder)
goFlakeInputs = {
  "github.com/amarbel-llc/tap/go" = {
    src = inputs.tap.packages.${system}.go-pkgs;
    subPath = "go";
  };
  # The dewey entry is INHERITED from tap's passthru — no need to
  # redeclare here. With inputs.tap.inputs.dewey.follows = "dewey",
  # the inherited entry points at the consumer's dewey input.
};
```

### Depth-1 is the normative limit

The protocol fixes depth-1 as the normative inheritance limit.
Implementations MUST NOT chase `passthru.goFlakeInputs` recursively
through inherited entries. Deeper-than-one transitive resolution is
deferred to the FOD-regen path tracked at
[amarbel-llc/nixpkgs#36](https://github.com/amarbel-llc/nixpkgs/issues/36);
until that path lands, deeply nested closures resolve by the consumer
declaring each direct producer's flake input and aligning shared deps
via `follows`. The depth-1 floor is sufficient for every closure shape
the fork has surfaced so far.

### Chains deeper than one level

Depth-1 inheritance does **not** transitively flatten a chain. What
holds instead is a per-level discipline that, when every party keeps
it, resolves chains of arbitrary depth:

- **(P) Producer duty.** Every producer declares its complete set of
  direct bridged modules in `mkGoPkgs`'s `goFlakeInputs`, so its
  `go-pkgs` passthru re-exports exactly its own directs. A producer
  that bridges siblings but omits this argument publishes outputs
  downstream consumers cannot inherit from (the gap madder itself
  shipped with initially — see igloo#39).
- **(C) Consumer duty.** A consumer's *effective* map (own
  declarations ∪ depth-1 inherited) must cover **every private
  (proxy-unreachable) module in its build's transitive import
  graph.** Inheritance reaches only the union of the consumer's
  direct producers' own directs; any private module that first
  appears two producers away MUST be declared by the consumer
  directly.

Worked example — the fleet's deepest live chain,
`dodder → madder → piggy → dewey`:

- dodder bridges madder directly. madder's passthru (duty P) carries
  madder's directs (tap, tommy, crap, hyphence, piggy once the
  cutover lands, **and dewey** — madder bridges dewey itself). So
  dodder inherits both piggy and dewey at depth-1 from madder, and
  piggy's own dewey requirement is satisfied by that inherited dewey
  entry — the module-path key is identical.
- The chain is nonetheless fragile through inheritance alone: if
  madder ever drops its own direct dewey usage, madder's passthru
  loses the dewey entry and dodder goes red — a change in the
  *middle* of the chain breaking the *end*. dodder immunizes itself
  by declaring dewey directly (which it already does), per duty C.
- Rev alignment: an inherited entry's derivation was evaluated
  against the **producer's** `flake.lock`, not the consumer's. A
  consumer that also holds the same flake input directly SHOULD add
  `follows` (`inputs.madder.inputs.piggy.follows = "piggy"`, etc.)
  so exactly one rev of each shared producer exists in the closure.
  Without `follows`, consumer-wins conflict resolution can yield a
  mixed-rev closure (consumer's rev for modules it declares,
  producer's locked revs for inherited ones) — buildable, but two
  sources of truth.

Consequently, for multi-level closures the RECOMMENDED steady state
is: **declare every private module in your transitive import graph
explicitly, with `follows` alignment; treat depth-1 inheritance as
the transition-time safety net** (it keeps you green while a producer
inserts a new dependency underneath you), not as the load-bearing
wiring. Producers keeping duty P is what makes the safety net exist;
consumers keeping duty C is what makes chains robust to producer
refactors. An eval-time coverage warning (producer `go.mod` requires
vs. the consumer's merged map) is the advisory check that surfaces
duty-C gaps before any building starts; see § *Producer-side passthru
inheritance* for its implementation status
([amarbel-llc/igloo#45](https://github.com/amarbel-llc/igloo/issues/45)).

## Limitations

The following limitations are known at protocol-design time. Each is
marked **open** (active gap, may be addressed by future revisions) or
**deferred** (out of scope, tracked elsewhere) with a pointer to the
relevant issue.

### Consumer side

- **Caller manages the `require` line in `go.mod`.** *(narrowed by
  igloo#39 / commit `82f3d8e`.)* The consumer MUST keep a
  syntactically valid `require` entry in `go.mod` for each bridged
  module. In the normal case that is the organic require the module
  was adopted with (real version, kept untouched, no sentinel); the
  bridge auto-injects a sentinel require only for the rare
  bridged-without-organic-require module. The organic version's
  staleness relative to `flake.lock` is designed and MUST NOT be
  "healed" — see § *Consumer interface* § *Example*.

- **Transitive deps of the flake input.** *(deferred to
  [nixpkgs#36](https://github.com/amarbel-llc/nixpkgs/issues/36).)*
  Organic transitive deps come in through the producer's
  `gomod2nix.toml`, which the bridge unions with the consumer's
  (consumer wins on conflict). Flake-input-driven transitive deps are
  inherited from `passthru.goFlakeInputs` at depth-1 only (see §
  *Multi-producer closures: `follows` + passthru inheritance*).
  Deeper-than-one-level inheritance — full FOD-regen of the merged
  module set — is the dedicated tracking issue.

- **Source-only inputs assumed.** *(open.)* `goFlakeInputs` entries
  MUST be derivations whose output is a Go module source tree (own
  `go.mod`, importable packages). Pre-built binaries or non-Go outputs
  are out of scope; the bridge has no opinion about how to consume
  them.

- **No `go build` outside Nix.** *(open, by design.)* This fork's Go
  projects already require `nix develop` for the toolchain; the bridge
  preserves that constraint. Editor and language-server workflows that
  parse `go.mod` directly may need the merged form materialized into
  the workspace; the materialization step is a follow-up.

- **No interaction defined with `buildGoRace` / `buildGoCover`.**
  *(open.)* These wrappers `overrideAttrs` on a
  `buildGoApplication`-produced derivation. They SHOULD be unaffected
  by `goFlakeInputs` (the merge happens before they wrap), but this
  needs concrete verification.

- **Missing-call-site lint.** *(deferred to
  [nixpkgs#41](https://github.com/amarbel-llc/nixpkgs/issues/41).)*
  Every `buildGoApplication` and `mkGoEnv` call in a consumer that
  consumes the same `gomod2nix.toml` MUST receive the same
  `goFlakeInputs` value. There is no enforcement today; missing
  call sites silently resurrect lockstep drift.

### Producer side

- **Multi-module repos.** *(open.)* A flake exposing several distinct
  Go modules cannot consolidate them under a single
  `packages.${system}.go-pkgs`. Naming for additional modules is left
  unspecified; a plausible future convention is
  `go-pkgs-<module-name>` (e.g. `go-pkgs-server`, `go-pkgs-client`),
  to be settled in this RFC or a successor when the first multi-module
  producer arrives.

- **Middleware ordering.** *(open.)* Composition is left-to-right via
  `foldl'`. Producers MUST order middlewares according to data-flow
  dependencies (e.g. codegen before formatters, formatters before
  linters). Out-of-order pipelines may succeed but produce
  inconsistent outputs; there is no built-in dependency resolution.

- **`subPath` does not slice middleware input.** *(open.)* Middlewares
  operate on the full `src` derivation. If a middleware should only
  run against a subtree of the producer's repo, that is the
  middleware's responsibility to handle internally (e.g.
  `cd $out/go && dagnabit export`). The convention does not push
  `subPath` semantics into the middleware contract because that would
  couple producer and consumer slicing decisions.

- **Per-package caching is not addressed.** *(deferred to
  [FDR-0001](../features/0001-numtide-go2nix-overlay-builder.md).)*
  This RFC defines the *shape* of producer output; cache reuse at
  Go-package granularity (e.g. when one facade rotates, other facades
  stay cached in downstream builds) is the concern of the numtide
  go2nix evaluation. The two compose: this RFC delivers generated
  source trees, FDR-0001's eventual work caches the resulting package
  compilations.

### Source-filter side

- **Regex, not globs.** *(open, by upstream constraint.)* `extras` are
  POSIX extended-regex strings (`builtins.match` semantics) because
  nixpkgs stdlib does not ship glob matching and `goSourceFilter`
  declines to invent new syntax.

- **Store-path naming preserves `src.name`.** *(open.)* The default
  naming is documented in § *Source filtering: `goSourceFilter`* §
  *Store-path naming*. Whether `${src.name}-go-source` would be more
  diagnostic is left to the first real adoption (tommy) to surface.

- **Single-tree assumption.** *(open.)* `goSourceFilter` operates on
  `src` as a single tree. Multi-module repos with separate Go modules
  in different subdirectories need per-module filter invocations.

- **Empty directories preserved.** Because the filter unconditionally
  allows directory traversal, empty directories that have no
  matching descendants are kept in the output store path. This is
  harmless for `go build` but may slightly increase the output NAR
  size compared to a strict "drop everything unmatched" interpretation.
  *(deferred: tracked as an open question for the first downstream
  adopter to surface as load-bearing or not.)*

## Open questions

The following items are unresolved at RFC-publication time. Each will
be revisited as the protocol promotes through `proposed → experimental
→ testing`.

1. **Lazy-trees interaction.** Theory: `lib.sources.cleanSourceWith`
   only imports matching files into the store, so the filter benefit
   composes with Nix's existing source-import laziness. The interaction
   with Nix's experimental `lazy-trees` feature (Git-input lazy
   materialization) is unverified. This RFC does not assert behavior;
   verification is required before `experimental → testing` promotion.

2. **`mkGoEnv` parity for `goSourceFilter` / `mkGoPkgs`.** The filter
   must apply identically to `mkGoEnv` calls so devshell module-graph
   matches build-time module-graph. Madder's adopter validation
   exercises the build side but not the devshell side; empirical
   verification on `mkGoEnv` is still pending as producers propagate.

3. **Store-path name preservation.** Documented behavior is "preserve
   `src.name`". Whether downstream adopters would prefer
   `${src.name}-go-source` is left to the first real adoption to
   surface; the answer changes the default but not the protocol shape.

## Appendix A — producer adoption checklist

Hand this list to a repo publishing its first `go-pkgs`. Each item
points at the normative section; the checklist adds nothing the spec
doesn't already say.

1. **Scope `src` to the module directory** for a single-Go-module
   repo (`src = self + "/go"` for polyglot layouts); full-repo
   filtering + consumer `subPath` only for multi-module repos.
   (§ *Producer `src` scoping*)
2. **Set `name` explicitly** (`"<repo>-go"`) when the module path's
   last element would infer an undiagnostic store-path prefix.
   (§ *Producer `src` scoping*; nixpkgs#49)
3. **Ship a fresh `gomod2nix.toml`** at the module root, and gate its
   freshness if your own builds don't consume it.
   (§ *Producers ship `gomod2nix.toml`*)
4. **Declare your direct bridges in `mkGoPkgs.goFlakeInputs`** —
   exactly the private/co-developed modules in your module's require
   graph, nothing public and proxy-fetchable. This populates
   `passthru.goFlakeInputs` so consumers inherit at depth-1.
   (§ *Multi-producer closures*, duty P)
5. **Self-consume from `go-pkgs-test`**: point your own Nix Go build
   at the published tree — `buildGoApplication` RECOMMENDED, another
   builder acceptable, `go vet ./...` check-only derivation as the
   floor when the repo has no Nix Go build.
   (§ *Self-consumption SHOULD*)
6. **Keep `version.env` inside the module directory** if you rely on
   version auto-read and you scoped `src`.
   (§ *Producer `src` scoping*)
7. **Name flake inputs predictably** (the producing repo's name) so
   consumers can `follows`-align without guessing.
   (§ *Multi-producer closures* § *Shared transitive deps*)
8. **Colocate the wiring in `gomod.nix`** (`go/gomod.nix` for
   polyglot repos): producer half, plus consumer half if the module
   bridges siblings. (§ *The `gomod.nix` convention*)
9. **Leave the vestigial require versions alone** — bridged modules'
   organic `require` versions freeze at adoption time by design; no
   hand-bumps, no self-heal lanes.
   (§ *Consumer interface* § *Example*)

## References

### Companion FDRs

- [FDR-0003 — Bridge Go module deps from flake inputs](../features/0003-bridge-go-flake-inputs.md).
  Source of the consumer-side problem statement, POC findings (commit
  `f99a3ff43278`, `zz-pocs/goflake-poc/`), and multi-producer-closures
  shape. Thinned to journey-only when this RFC supersedes its
  interface sections.

- [FDR-0004 — go-pkgs producer convention + middleware](../features/0004-go-pkgs-producer-convention.md).
  Source of the producer-side problem statement, the codegen-middleware
  motivation, and the `mkGoPkgs` shape exploration. Thinned to
  journey-only when this RFC supersedes its interface sections.

### Proof-of-concept

- POC commit `f99a3ff43278` — the three-phase probe of the
  `require <module> v0.0.0-<sentinel> + replace => ./.flake-inputs/<name>`
  shape at `zz-pocs/goflake-poc/`. Identified the concrete blocker
  (`pwd + "/${value.path}"` eval-time path import) that the bridge
  must avoid.

### Originating issues

- [nixpkgs#39 — `gomod.nix` convention for consumer-side goFlakeInputs](https://github.com/amarbel-llc/nixpkgs/issues/39)
  surfaced the consumer convention from madder#211 adoption.
- [nixpkgs#40 — filtered-source `go-pkgs` over bare `self`](https://github.com/amarbel-llc/nixpkgs/issues/40)
  surfaced the `goSourceFilter` need.
- [nixpkgs#41 — linter for missing `goFlakeInputs` threading](https://github.com/amarbel-llc/nixpkgs/issues/41)
  follow-up enforcement gap referenced from § *The `gomod.nix` convention*.
- [nixpkgs#46 — split `go-pkgs` output: `mkGoPkgs` emitting `{ go-pkgs, go-pkgs-test }`](https://github.com/amarbel-llc/nixpkgs/issues/46)
  surfaced the audience-split problem (prod consumers vs. self-consumption /
  test runners) and motivated the dual-output amendment now reflected in
  § *Producer interface*.

### Tracking issues

- [nixpkgs#32 — consumer-side `goFlakeInputs` implementation](https://github.com/amarbel-llc/nixpkgs/issues/32).
- [nixpkgs#35 — `mkGoPkgs` helper and middleware contract](https://github.com/amarbel-llc/nixpkgs/issues/35).
- [nixpkgs#36 — deeper-than-one transitive resolution (FOD-regen path)](https://github.com/amarbel-llc/nixpkgs/issues/36).

### Downstream consumers

Downstream Go projects expected to evaluate against this RFC:
`dagnabit`, `madder`, `maneater`, `dodder`, `chrest`, `nebulous`, and
`tommy`.
