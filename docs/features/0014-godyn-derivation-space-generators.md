---
status: experimental
date: 2026-11-11
promotion-criteria: implementation lands with a green flake check over stub generators; one real consumer (ringmaster) builds with dagnabit and tommy generated in derivation space and no committed generated files; no lever below moved for two weeks of consumer use.
---

# godyn derivation-space generators

## Problem Statement

Generated Go (dagnabit facades under `pkgs/`, tommy `*_tommy.go` companions) is
committed to the repo, and every generator carries a version stamp in its header.
A lock bump that moves a generator restamps every generated file; the pre-commit
hook, frozen from an older master, restages the raw output; the merge gate's
drift check then fails (circus#423, spinclass#459/#475, conformist#153). The
committed copy is a cache of a pure function of (source, generator), kept in
the one place that cannot be kept fresh. godyn already runs generators purely
(`passthru.codegenCheck` / `codegenPatch`); it only uses the result to compare,
never to build.

## Interface

A new argument on `buildGodynModule` and `buildGoAuto` (godyn backend; the bga
backend runs the same stages through the same shared tree):

    generators = [
      { name = "dagnabit"; command = "dagnabit export"; nativeBuildInputs = [ dagnabit ]; }
      { name = "tommy";    command = "go generate -run tommy ./..."; nativeBuildInputs = [ tommy ]; }
    ];

- Stages run in list order. Stage N sees the tree stages 1..N-1 produced
  (generated output may be the input of a later generator: a dagnabit facade is
  imported by the package tommy type-loads). Order is the author's job; a wrong
  order fails with the generator's own error.
- Each stage is `codegenPatch` over the previous stage's tree, applied with
  `git apply -p2`: pure, offline, in the vendored/rendered module tree, cached.
- The module is built from the final tree. `src` stays the hand-written source;
  nothing generated is committed.
- New passthru: `generatedSrc` (final tree), `generatorStages` (per-stage
  trees), `src` unchanged. `codegenCheck` keeps its meaning for modules that
  still commit generated files.

Three changes make this work (each is the fix for a verified blocker, below):

1. **Lazy graph for stage modules.** A stage needs only the vendored tree, never
   the package graph. `buildGodynModule` currently forces the graph (via the
   `mainPkg` decision) just to build its attrset, and the graph is `go list`
   over the module, which fails on a tree whose generated imports do not exist
   yet. The extension makes `passthru.codegenCheck`/`codegenPatch`
   (and the stage modules) independent of the graph, so stage modules need no
   stub graphFile. Only the final module derives its graph.
2. **Derivation-safe `src`.** When `src` is a derivation output, its eval-time
   path may be unknown (a derivation downstream of a content-addressed
   derivation is a deferred path; strings read `/<hash52>`). godyn and gomod2nix
   then must not call `builtins.path`/`cleanSourceWith` on it. Replacement: per
   package a copy derivation (content-addressed `runCommandLocal` copying exactly
   the files the graph lists for the package, from `${src}/<dir>`), and a
   dep-files derivation for go.mod/go.sum/gomod2nix.toml. These are keyed by
   file content, so the merkle-delta invariant (an edit to one package rebuilds
   that package and its dependents only) is preserved. Path-valued `src`
   keeps the existing `builtins.path` route unchanged.
3. **Seed for generators that build themselves** (open item, below).

Implemented (godyn/generators.nix, `codegenOnly` in build-godyn-module.nix,
`pathFiltered`/`pathWhole` there and a dep-files derivation in gomod2nix):
the lazy graph is the `codegenOnly` argument (the module returns only
`passthru.codegenCheck`); the derivation-safe `src` chooses the copy-derivation
route when `src`'s path is not a store path at eval time (`srcPathKnown`); the
seed question is answered by `passthru.generatorsFixedPoint`. Covered by
`godyn-generators-*` checks over stub content-addressed generators.

## Examples

    packages.app = pkgs.buildGoAuto {
      pname = "app";
      src = self;
      manifest = ./go.nix;
      inputs = { inherit tommy; };
      generators = [ ... as above ... ];
    };

The prototype (`zz-pocs/godyn-gen-poc`, committed 2a41b81) is the same chain as
a user-space helper over the existing `codegenCheck`:

- facade `pkgs/greeter/main.go` (dagnabit output) imported by `internal/bravo/cfg`
  (input to tommy), which yields `cfg_tommy.go` (tommy output), imported by
  `cmd/app`. `just zz-pocs/godyn-gen-poc/build-test` passes.

## What was verified (prototype)

VERIFIED = I ran it.

- End to end chain above builds and runs; the tracked fixture holds no
  generated file (asserted at eval time).
- Whole chain after an edit of the internal package: 7 s wall on the toy module
  (3 source renders, 2 patches, graph IFD, 4 package compiles, link).
- Generator-version-only bump (simulated: same tommy, header rewritten): only
  the tommy stage, the graph and `cfg`'s compile re-ran; the final binary store
  path was identical (content-addressed early cutoff); 5 s.
- Wrong generator order (tommy before dagnabit) fails with tommy's
  "could not import .../pkgs/greeter".
- Blocker 1 (graph strictness): building a stage module over the raw tree fails
  with `godyn-gen: go list: ... cannot find module providing package
  example.com/gen/pkgs/greeter`; the same error is what `go vet`/gopls print on
  a fresh checkout without committed facades.
- Blocker 2 (deferred source): with godyn-built (content-addressed) generators
  the generated tree is a deferred path; the final module fails with `path
  '/<hash>' does not exist` from `go-cache-env`'s `cleanSourceWith`, also under
  `--impure`. With the input-addressed bga builds of the same generators
  (`passthru.bga`) the identical chain builds. Per-package `builtins.path`
  sites in `build-godyn-module.nix` (srcDirFor and the test/run sources) have the same
  dependence; I fixed none of them in the prototype (THEORY that they fail the
  same way once go-cache-env is passed).

## tommy as generator

tommy is a go.nix module built by godyn and is also the runtime library the
generated code imports. Verified in the prototype: the generator binary comes
from tommy's flake, the library from its `go-pkgs`, both from one flake input.
There is no cycle because tommy's production closure contains no generated file
(the only `*_tommy.go` in the repo is a testdata fixture). tommy generate
type-loads the package with go/packages, so the stage runs in the vendored tree
with the bridged tommy go-pkgs, which godyn already provides. Its stamp
(`tommy <version> (<commit>)`) is `unknown` for tarball inputs (tommy#140); in
derivation space the stamp is irrelevant to correctness.

## dagnabit self-bootstrap (open item) and proposed answer

READ, not run: `cmd/dagnabit/main.go` imports `libs/dewey/pkgs/dagnabit` and
`pkgs/dagnabit_rust`, facades that dagnabit itself generates. In derivation
space the new dagnabit needs facades from a dagnabit.

Proposed answer: a **seed**. The module that builds dagnabit lists
`nativeBuildInputs = [ dagnabitSeed ]` in its `generators`, where
`dagnabitSeed` is a pinned previous dagnabit (a flake input at the last release,
bumped by hand, never by the cascade). Facades are pure alias files that differ
across dagnabit versions only in the header stamp, so the seed's output
compiles identically. Guard it with a check, `passthru.generatorsFixedPoint`:
run the same stages with the newly built binary and require the tree equal to
the seed's tree modulo the stamp line; it fails loudly if a dagnabit change
alters facade shape without a new seed. Alternative considered and rejected:
keep dagnabit's own `pkgs/` committed (the dagnabit module opts out of
`generators`); that leaves exactly one repo with the staleness problem, which
is acceptable as a fallback if the fixed-point check proves noisy.

## Consumer adoption (ringmaster is the motivating case)

Not done here (separate ruling); what a consumer must do:

1. Add `generators` to its `buildGoAuto` call with dagnabit (and tommy if it has
   `*_tommy.go`) from its flake inputs; remove the committed `pkgs/*/main.go`
   facades and `*_tommy.go` files and add them to `.gitignore` so a local
   `dagnabit export` does not stage them.
2. Keep `//go:generate dagnabit export` / `//go:generate tommy generate`
   directives in source; they remain the opt-in markers the stages read.
3. For editor/`go vet`/gopls on a checkout: the raw tree no longer loads (the
   facade import is missing). Provide a dev recipe that runs the stages into the
   working tree, ignored by git (the existing `godyn-go` escape hatch does this
   with `goRun`), or work against `generatedSrc`. This is the main ergonomic
   cost.
4. Remove the codegen-repair linter wiring and the `codegenCheck` flake checks
   for those generators.

Pre-commit / facade-drift story: with no committed generated files there is
nothing for the frozen pre-commit hook to restage and no facade-drift check to
fail, so circus#423, spinclass#459/#475 and conformist#153 stop applying to
these files. Dagnabit's conformist formatting of facades
(`DAGNABIT_CONFORMIST_CONFIG`) is not run in derivation space unless the stage
supplies the raw conformist and config; unformatted jennifer output is fine for
compilation but is not byte-identical to today's committed facades.

## Limitations

- Raw checkout does not build with plain `go build`; the nix builders are the
  only path (consistent with FDR 0008's stance).
- Generators that need the network or write outside the module tree are out of
  scope (stages are pure and offline).
- Generator stages re-run on any source change (whole-tree input); the
  per-package compile cache absorbs unchanged outputs, so the cost is the
  generator itself (seconds on the toy module).
- vet/lint lanes over generated packages are not exercised.

## Not tested

- A real second generator revision (only a simulated header-only bump).
- Real-scale module (dewey/ringmaster size) timings; cold generator-binary
  build timing in isolation.
- dagnabit self-bootstrap and the fixed-point check (design only).
- The byte-identity of derivation-space facades with committed ones
  (conformist formatting).
- Editor/gopls flow with the dev recipe in adoption step 3.
- Non-x86_64-linux builders, test (`tests = true`) and cover/race lanes over a
  generated tree.

## Tuning Levers

| Lever | Current | Rationale | Change signal |
|---|---|---|---|
| stage granularity | whole-tree per stage | simplest correct; cached per input tree | generator wall time dominates edits on a large module |
| stamp in generated header | kept (generator default) | generators unchanged | consumers want a stable tree across bumps; ask generators for a stamp-free flag |
| seed pin for self-building generators | manual flake input | cascade must not move it | seed lags enough to break the fixed-point check often |

## More Information

- FDR 0008 (nix-authoritative go modules), godyn(7) "Codegen drift".
- Prototype: `zz-pocs/godyn-gen-poc/` (commit 2a41b81).
- circus#423, spinclass#459, spinclass#475, conformist#153.
