---
status: draft
date: 2026-10-26
promotion-criteria: |
  draft → proposed: the operator has ruled on § Decisions; conformist's
  eng preset carries a linter for the checks in § Conformance (igloo owns
  this text, conformist enforces it: operator, 2026-10-25); igloo ships a
  conforming fixture flake built by its own test lane.

  proposed → experimental: two fleet repos conform (a producer and a pure
  consumer), and conformist's codegen-repair linter repairs one of them
  from the `go-codegen` check alone, with no per-repo configuration.

  experimental → testing: eng's `update-nix` cascade and doppelgang read
  `go-module` from every repo they touch; no repo needs onboarding beyond
  adopting the tree.

  testing → accepted: every godyn consumer in the fleet conforms for a
  release cycle; the survey in § Current state is deleted as history.
---

# RFC 0003 — the standard godyn tree

> **Draft.** Written by session igloo/slim-pecan on 2026-10-26 for
> igloo#81 (operator decision 2026-10-25: the RFC lives in igloo as a
> sibling of RFC 0001, with normative MUST/SHOULD wording; godyn(7) and
> the README point at it; conformist enforces it). The operator ruled on
> § Decisions the same day; the normative text applies them as written.
> Status stays draft until conformist's linter and igloo's fixture exist.

## Decisions (operator, 2026-10-26)

1. **Canonical output name:** `packages.${system}.go-module`, the name
   igloo#81 proposed. The alternatives (`godyn`, `go`) say less or clash
   with the toolchain's own name.
2. **Several modules in one repo:** the primary module is `go-module`;
   every other module is `go-module-<name>`, `<name>` being the module
   directory relative to the repo root with `/` replaced by `-`. A repo
   with no primary (a monorepo whose `packages.default` ships none of
   them) omits the bare name. Tooling enumerates the prefix.
3. **Standard check names:** `go-tests`, `go-vet`, `go-lint`,
   `go-codegen` (or `go-codegen-<tool>` for independent generators), with
   the same `-<name>` suffix for secondary modules. Today's names
   (`<repo>-godyn-tests`, `tommy-codegen`, `vet`, `lint`) all differ from
   one another; a fixed set lets tooling and humans find a lane without
   reading the flake.
4. **The manifest is go.nix, without a legacy tier:** a module MUST use
   it (FDR 0008). A module still on a tracked go.mod + gomod2nix.toml
   does not conform and fails the linter; the migration is
   `godyn-go -I .`. (The author had proposed a reported-but-passing
   legacy shape; the operator chose the stricter rule.)
5. **`codegenPrefix` is mandatory on codegen checks:** a repo-root repair
   lane cannot place a patch without it, and godyn derives it only for
   the one `src` shape it can verify (godyn(7) § Codegen drift). A check
   whose prefix is `null` does not conform.
6. **Tests ride on `go-module`:** it is built with `tests = true`, so
   `checkAll` and `testWith` are reachable from the canonical output. The
   one exception is the igloo#88 shape (tests that execute the module's
   own binary), where the tested instance is exposed as
   `go-module-tests` and `go-tests` is built from it.

## Conventions

The keywords MUST, MUST NOT, SHOULD, SHOULD NOT, MAY are to be
interpreted as described in RFC 2119 and RFC 8174 when, and only when,
they appear in all capitals.

## Abstract

Every fleet repository that builds Go with igloo's builders wires its
module, checks and generated-code drift differently: `packages.default`
is usually a wrapper rather than the module, the test, vet and lint
checks carry a different name in each flake, and codegen checks are
wired directly, through a local helper, or not at all (§ Current
state). Fleet tooling — conformist's codegen-repair linter, eng's
`update-nix` cascade, doppelgang, the planned machine-editable flake
shape — therefore cannot rely on any shape and every improvement falls
back to per-repository onboarding.

This RFC fixes the *tree*: the flake outputs a godyn consumer exposes,
their names, what each one is, and the contract each carries, so that a
tool given only a flake reference can find the module, run its lanes,
and repair its generated files. It standardizes shape, not
implementation: igloo's builders already provide everything the tree
requires (godyn(7), mkGoPkgs(7)), and the RFC names which of their
outputs go where.

## Terminology

- **Module**: one Go module in the repository, built by `buildGoAuto`
  (godyn(7)); its result carries the passthru surface this RFC relies on.
- **Primary module**: the module whose binaries `packages.default` ships
  (or the only module).
- **Secondary module**: any other module in the same repository.
- **Lane**: one of the per-package check aggregates godyn exposes:
  `checkAll` (tests), `vetAll`, `lintAll`, and a `codegenCheck` result.
- **Repair lane**: a tool outside the flake (conformist's codegen-repair
  linter) that finds codegen checks by their `passthru.codegenPatch` and
  applies the patch at pre-commit (igloo#80).
- **Producer**, **consumer**, **`go-pkgs`**, **`go-pkgs-test`**: as in
  RFC 0001.
- **`<name>`**: a secondary module's suffix, § Multiple modules.

## The tree

A conforming flake, one module, a producer:

    flake.nix
    ├── go.nix                       the module's manifest (FDR 0008)
    ├── packages.<system>
    │   ├── go-module                buildGoAuto { pname; src = go-pkgs-test; manifest = ./go.nix;
    │   │                                          inherit inputs; tests = true; }
    │   ├── default                  go-module, or a wrapper composing it (manpages, completions)
    │   ├── go-pkgs                  mkGoPkgs { src = self; manifest = ./go.nix; inherit inputs; }
    │   └── go-pkgs-test
    ├── checks.<system>
    │   ├── go-tests                 go-module.passthru.checkAll
    │   ├── go-vet                   go-module.passthru.vetAll
    │   ├── go-lint                  go-module.passthru.lintAll
    │   └── go-codegen               go-module.passthru.codegenCheck { command; nativeBuildInputs;
    │                                                                  codegenPrefix = ""; }
    └── devShells.<system>.default   godyn-go, godyn-test on PATH

A pure consumer drops `go-pkgs` and `go-pkgs-test` and builds
`go-module` from `self`. Each section below is normative for one row.

## The canonical module output

A conforming flake MUST expose `packages.${system}.go-module`: the
result of `buildGoAuto` for the primary module, unwrapped. Its passthru
is the surface every other row of the tree and every fleet tool reads:
`checkAll`, `vetAll`, `lintAll`, `testWith`, `codegenCheck`, `goRun`,
`ingest`, `backend`, `native`, `bga`, `version` (godyn(7)).

`packages.${system}.default` MAY be `go-module` itself or a derivation
composed from it (a `symlinkJoin` with manpages, a wrapper script). It
MUST NOT be the only path to the module: a tool MUST NOT have to unwrap
`default` to reach a passthru.

`go-module` SHOULD be built with `tests = true`, so `checkAll` and
`testWith` are reachable from it. When the module's tests execute its
own binary (igloo#88: a second instance with the first in
`nativeCheckInputs`), the tested instance MUST be exposed as
`packages.${system}.go-module-tests`, and `go-tests` (§ Standard checks)
MUST be built from it. The compiles are shared between the two instances
(content-addressed), so the second output costs only the test runs.

`buildGodynModule` directly, bypassing the selector, is permitted only
for a lane that needs an argument `buildGoAuto` does not forward; the
canonical output itself MUST come from `buildGoAuto`, so that
`passthru.backend`, `native` and `bga` exist on it.

## The manifest

A module MUST describe its dependencies in a `go.nix` at the module
root, passed as `manifest` (FDR 0008, godyn(7) § GO.NIX MANIFEST), with
the flake's inputs passed as `inputs`. Fleet modules MUST be declared as
`flakeInputs` entries, never as hashed `require`s of a fleet module's
pseudo-version: the flake input's rev is the only version (RFC 0001).

A module that still tracks `go.mod`, `go.sum` and `gomod2nix.toml`
(RFC 0001's gomod.nix convention) does not conform, whatever the rest of
its tree looks like; the migration is `godyn-go -I .` followed by
removing the three files (godyn(7) § The escape hatch). Dependency
changes on a go.nix module go through `godyn-go` (the escape hatch),
never through an ambient `go`.

## Backend selection

`go-module` MUST NOT pass `strategy`, and the tree MUST NOT be gated by
a hard-coded system list: `buildGoAuto` picks godyn on every system
igloo supports and buildGoApplication elsewhere (godyn(7) § buildGoAuto,
FDR 0007). A lane that only exists on one backend is keyed by
`passthru.backend`, never by `system`.

A deliberately non-godyn build MAY exist as a separate, named output
(`go-module-bga` for a buildGoApplication release artifact;
`go-module-static` once igloo#78 lands); such an output is never the
canonical one.

## Standard checks

A conforming flake MUST expose, on every system it defines outputs for:

| Check | Value | Meaning |
|---|---|---|
| `checks.${system}.go-tests` | `go-module.passthru.checkAll` (or `go-module-tests.passthru.checkAll`) | every per-package test run |
| `checks.${system}.go-vet` | `go-module.passthru.vetAll` | every local package's vet, test variants included |
| `checks.${system}.go-lint` | `go-module.passthru.lintAll` | the godyn-lint suite (the fleet standard, igloo#87) |

On a system where `passthru.backend` is not `native`, `go-tests` MUST
still be a derivation that runs the module's tests (the module itself,
whose check phase runs `go test ./...`), and `go-vet` / `go-lint` MAY be
omitted. In practice every system igloo supports is a godyn system, so
the fallback is a guard, not a lane.

Further lanes MAY exist under any other name (a race run, a fuzz seed
sweep, a dewey analyzer run). The four names above (and their
`-<name>`-suffixed forms, § Multiple modules) are reserved for the
meanings in this RFC.

## Codegen contract

A module with generated files MUST expose its drift check as
`checks.${system}.go-codegen`: the result of
`go-module.passthru.codegenCheck { command; nativeBuildInputs;
codegenIncludes; codegenPrefix; }` (godyn(7) § Codegen drift). The
result carries the three passthru attributes igloo#80 defined and this
RFC makes normative for the fleet:

- `passthru.codegenPatch` — the repair: a pure, offline derivation whose
  `$out/patch` is the generators' diff against `src`, empty when the tree
  is current. The check is "the patch is empty".
- `passthru.codegenIncludes` — extra trigger globs for generators driven
  by non-Go files; a repair lane unions them with `*.go`, `flake.lock`
  and `go.nix`.
- `passthru.codegenPrefix` — the module root relative to the repo root
  (`""` for a root module). It MUST be a string, never `null`: a
  repo-root repair lane applies the patch with
  `git apply -p2 --directory=<codegenPrefix>`, and godyn can only derive
  the prefix for a `src` of the form `self` / `self + "/dir"`. Any other
  `src` (a path literal, a filtered or rendered tree, `go-pkgs-test`)
  MUST pass `codegenPrefix` explicitly.

Generators that feed each other (dagnabit then tommy rewriting one file)
MUST be one `command`, run in order, in one check: two checks' patches
are each computed against `src` alone and do not compose. Independent
generators MAY be separate checks named `go-codegen-<tool>`; a repair
lane applies each patch and rebuilds the rest against the repaired tree.

A repair lane finds codegen checks by `passthru.codegenPatch` on any
`checks.${system}.*`, not by name; the names exist for humans and for
the per-module suffix rule. A check carrying `codegenPatch` under a
non-standard name still gets repaired, and a conformance check reports
its name.

A module whose generated files are produced by a tool the repository
itself builds (tommy's own `*_tommy.go`) follows the same rule; the
tool enters through `nativeBuildInputs`, and `goRunInputs` on the
module makes `godyn-go -- go generate ./...` find it too.

## Multiple modules

A repository with more than one Go module exposes the primary module
per § The canonical module output and every secondary module as
`packages.${system}.go-module-<name>`, where `<name>` is the module
directory relative to the repository root with each `/` replaced by `-`
(`nix-cache/` → `go-module-nix-cache`; `libs/go-mcp/` →
`go-module-libs-go-mcp`). A repository MAY document a shorter `<name>`
in its AGENTS.md; the directory form is the default a tool can compute.

Each secondary module's checks carry the same suffix: `go-tests-<name>`,
`go-vet-<name>`, `go-lint-<name>`, `go-codegen-<name>` (and
`go-codegen-<name>-<tool>`). A repository with no primary module omits
the bare names and exposes only suffixed ones.

A secondary module that is itself a producer meets RFC 0001's limit of
one `go-pkgs` / `go-pkgs-test` pair per flake (mkGoPkgs(7)
§ LIMITATIONS): the name of a second pair is unspecified there and this
RFC does not specify it either; until it is, such a module is published
from a flake of its own or bridged by `subPath` from the single pair.

Sibling modules in one repository that depend on each other use
`moduleDir` and path `replace`s inside one tree (godyn(7)
§ buildGodynModule, igloo#73) or, when each is a producer in its own
right, the `flakeInputs` route through `self`. The former keeps one
graph; the latter makes the dependency a flake edge like any other.

## Producers

A repository whose module other fleet flakes import MUST publish
`packages.${system}.go-pkgs` and `go-pkgs-test` through `mkGoPkgs` with
the same `manifest` (RFC 0001, godyn(7) § Producers). Its `go-module`
SHOULD be built from `go-pkgs-test` with that manifest (self-consumption:
the producer builds what consumers see, and the one build then carries
`ingest` and `goRun` for `godyn-go`).

A module below the repository root publishes with `subPath` on
`mkGoPkgs` equal to the module directory; consumers bridge with the same
`subPath` in their `flakeInputs`; and its `go-module` passes the same
directory as `codegenPrefix`.

## Per-system availability

A conforming flake defines `packages`, `checks` and `devShells` for every
system igloo's builders support (`godynSystems`, godyn(7)
§ buildGoAuto). Derived graphs are per-system by construction, so
evaluating another system's `go-module` needs a builder for that system
(import-from-derivation, igloo#75); this is accepted (FDR 0008), and a
flake MUST NOT work around it by committing per-system graphs for the
canonical output (FDR 0008 recommends derived graphs; a committed graph
remains available to a lane that needs one).

## Developer tooling

The default devShell SHOULD put `godyn-go` and `godyn-test` from igloo on
PATH and SHOULD NOT provide an ambient Go toolchain: dependency changes
go through the escape hatch and the inner test loop through
`godyn-test` (godyn(7)). A repository MAY wrap both in justfile recipes.

Both CLIs select the module with `-A`, defaulting to
`packages.<system>.default`; under this RFC the default SHOULD be
`go-module` when the flake exposes it (an igloo change, § What igloo
changes).

## Conformance

The checks a linter (conformist's eng preset) runs over a flake's
evaluated outputs, each a one-line verdict:

- **C1** `packages.<system>.go-module` exists and is a `buildGoAuto`
  result (`passthru.backend` and `passthru.native` are set).
- **C2** `checks.<system>.go-tests`, `go-vet`, `go-lint` exist and are
  the matching passthru of `go-module` (or `go-module-tests` for
  `go-tests`); the same for every `go-module-<name>`.
- **C3** every `checks.<system>.*` carrying `passthru.codegenPatch` has a
  string `codegenPrefix`, and is named `go-codegen`,
  `go-codegen-<tool>` or a `-<name>`-suffixed form (a name violation is
  a warning; a `null` prefix is a failure).
- **C4** `go-module` (and every `go-module-<name>`) was built with a
  `manifest` (go.nix); a module on a tracked go.mod fails.
- **C5** no `strategy` on `go-module`, and the standard outputs exist on
  every system the flake defines.
- **C6** a flake that is a `flakeInputs` target of another fleet flake
  exposes `go-pkgs` and `go-pkgs-test`.

igloo ships a conforming fixture flake and builds its tree in its own
test lane, so the reference shape is executable, not only described.

## What igloo changes

Follow-ups this RFC implies for igloo, none of which block adoption:

- `godyn-go` and `godyn-test` default `-A` to `go-module` when the flake
  exposes it, else `default` as today.
- A conforming fixture flake under `pkgs/build-support/godyn/tests/`
  exercised by a flake check (the C1–C6 reference).
- `godyn(7)` gains a short section pointing here; mkGoPkgs(7) and the
  README point here from the producer and layout rows.
- If `godynSystems` is not already exported for consumers' `eachSystem`,
  export it.

## Current state (surveyed 2026-10-26)

Read from each sibling repository's flake.nix and the files it imports
on 2026-10-26 by a read-only sweep of the fleet checkouts; cells marked
`?` were inferred from context rather than read in full. This section is
the migration's starting line and is deleted when the RFC is accepted.

| repo | module output today | manifest | codegen check | tests / vet / lint checks |
|---|---|---|---|---|
| tommy | `tommy-gonix` (raw); `default` a wrapper | go.nix (producer) | local `goNixCodegen` over `codegenCheck`; exported as `lib.goNixCodegen` | `go-tests`, `go-vet`, `go-lint` |
| madder | not exposed (`default` a wrapper); `madder-godyn-tests` is `checkAll` | tracked go.mod (producer) | none (conformist tommy/dagnabit linters) | `madder-godyn-tests`, `madder-vet-*` |
| clown | not exposed; `clown-godyn-tests` is `checkAll` | go.nix (producer) | none | `clown-godyn-tests`, `clown-godyn-race-tests` ? |
| crap | per-binary outputs; `default` a symlinkJoin | go-crap/go.nix (producer, `subPath`) | none | `go-tests`, `go-vet`, `go-lint` |
| troupe | `troupe` (raw), `default` = it | tracked go.mod (producer) | direct, `codegenPrefix = ""` | `troupe-tests` |
| conformist | `conformist-godyn-tests` (raw); `default` a symlinkJoin | go.nix | custom passthru ? | `conformist-tests`, `vet`, `lint` |
| spinclass | `default` (raw) | go.nix | direct, two checks | `spinclass-tests`, `vet`, `lint` |
| moxy | `moxy-native` ?; `default` a symlinkJoin | go.nix (producer) | direct | `go-vet`, `go-test`, `go-test-race` (x86_64-linux only) |
| chrest | `default` (raw) | go/go.nix (producer, `subPath`) | direct, two checks, `codegenPrefix = "go"` | `chrest-tests` |
| dodder | buildGoApplication only | tracked go.mod (producer) | none | none |
| piggy | not exposed; `piggy-go-tests` is `checkAll` | tracked go.mod (producer) | none | `go-tests`, `go-vet` ? |
| nebulous | `nebulous` (raw) | go.nix (producer) | none | `nebulous-tests`, `vet`, `lint` (with bga fallback) |
| roustabout | `default` (raw) | go.nix | direct (`layout`) | `tests` |
| juggler | not exposed; `juggler-godyn-tests` is `checkAll` | go.nix (producer) | direct, two checks | `juggler-godyn-tests`, `-race-tests` |
| cutting-garden | `cutting-garden-godyn-tests` (raw) | go.nix (producer) | local `godynCheck` over `codegenCheck`, two checks | `cutting-garden-godyn-tests`, `vet`, `lint`, dewey lanes |
| circus | `circus-go` (raw, one of several modules) | go.nix (circus-cli); tracked go.mod (nix-cache, provider) | direct (`circus-cli-layout`) | `circus-cli-tests` |
| maneater | buildGoAuto `maneater-man-unwrapped` | tracked go.mod | direct (`tommy-codegen`) | ? |

Producers on buildGoApplication without godyn (hyphence, ringmaster,
langlang, tap, purse-first) and consumers on it alone (papi, doppelgang,
trapeze, bats) publish `go-pkgs` where they are producers and have no
godyn lanes; they adopt the tree when they adopt `buildGoAuto`. posh's
Go helpers use nixpkgs' `buildGoModule` and are out of scope.

Two observations from the survey shape the RFC: no repository exposes
the raw module under a common name (five do not expose it at all), and
`codegenIncludes` is used nowhere while `codegenPrefix` appears in two
repositories, so the repair lane's prefix rule (decision 5) is the
contract most at risk of silent misuse.

## Limitations

- The RFC standardizes godyn consumers. A repository on
  buildGoApplication alone conforms only once it moves to `buildGoAuto`;
  the RFC does not define a tree for the bga-only case.
- Cross-system evaluation stays bounded by igloo#75 (a builder per
  evaluated system) and the darwin/aarch64 validation gap (igloo#33).
- Check names are a convention a linter can verify, not a mechanism: a
  tool that needs a lane and finds it under another name can still read
  it from `go-module`'s passthru.
- The machine-editable flake shape (eng's FDR, a structured file driving
  a thin standard flake.nix) is the next layer above this tree and is
  not specified here; this RFC gives it the output names to generate.

## More Information

- igloo#81 (the tracking issue), igloo#80 (the codegen contract),
  igloo#87 (the lint standard), igloo#88 (tests that run the module's
  own binary), igloo#73 (several go.nix modules in one tree), igloo#75
  (per-system import-from-derivation), igloo#78 (the static lane).
- RFC 0001 (flake-input-go_mod), the producer/consumer protocol whose
  outputs this tree names; RFC 0002, the Rust twin.
- FDR 0007 (godyn as the only Go builder), FDR 0008 (go.nix as the only
  source of truth), FDR 0012 (the toolchain registry).
- godyn(7), mkGoPkgs(7), gomod2nix(7).
