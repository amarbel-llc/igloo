---
status: experimental
date: 2026-09-14
promotion-criteria: |
  exploring → proposed: the manifest shape below is settled on one
  fixture: igloo renders a go.mod from it inside a derivation, derives
  the fixture's package graph from it at eval time (no committed
  graph.json), and godyn builds the fixture with no go.mod in the source
  tree; the round trip go.mod → manifest → go.mod is lossless for every
  field the manifest owns.

  proposed → experimental: every go.mod-dependent part of spinclass (the
  tracer bullet, § Tracer bullet: spinclass) has a first-class godyn
  solution with an igloo fixture — including the escape hatch and a pure
  codegen drift check — and only then spinclass cuts over: it builds,
  tests, vets, lints and verifies codegen from its go.nix with its
  committed go.mod, go.sum and gomod2nix.toml removed. gopls and dlv are
  out of scope.

  experimental → testing: dependency updates happen only through the
  manifest (directly or via ingest) on at least two consumers; each
  third-party module's own Go language version reaches its compiles.

  testing → accepted: a release cycle with no consumer re-committing an
  authoritative go.mod, and gomod2nix retired as a consumer-facing tool
  fleet-wide (gomod2nix.toml, the gomod2nix CLI, mkGoEnv and the drift
  linter); buildGoApplication may remain an internal builder.
---

# A nix manifest as the only source of truth for Go modules

## Problem Statement

A fleet Go module's build inputs live in four files that must agree:

- **go.mod** — module path, Go language version, requires, replaces;
- **go.sum** — `h1:` checksums the go command verifies;
- **gomod2nix.toml** — NAR hashes the nix vendor tree fetches by;
- **graph.json** — godyn's committed package graph (FDR 0007), regenerated
  by hand whenever imports or files change.

RFC 0001 removed one lockstep (fleet modules' pseudo-versions against
`flake.lock`) by synthesizing `replace` directives at eval time, but it did so
by *editing* go.mod on the fly: the organic go.mod stays authoritative and
nix patches it. Everything else still flows go.mod → the other files, through
tools run outside nix.

Under FDR 0007 the fleet builds Go only through godyn, and the go toolchain is
**not supported outside nix at all**. With that rule, go.mod's reason to be a
committed, hand-edited file — so ambient `go` and editors can read it from the
checkout — no longer holds. go.mod can become what nix renders it into: a
build input generated inside derivations.

It would also carry information go.mod handling loses today. godyn compiles
every package with `-lang=${goVersion}` (one version for the whole graph)
rather than each module's own `go` directive, which `go build` honors per
module. A third-party module declaring an older language version (for
example, before Go 1.22's per-iteration loop variables) may then compile with
different semantics under godyn than under `go build`. This is unverified —
it needs a fixture whose output depends on the language version — but a
manifest that records each module's Go version gives godyn what it needs to
pass the right `-lang` per package either way.

## Interface (sketch)

**Decided 2026-09-14:** the manifest is **`go.nix`** in the module root, a
**plain nix attrset of data** — no function, no nix expressions — so `render`
and `ingest` read and write it without evaluating a flake. Field details below
are still a sketch to be settled by the first fixture:

```nix
{
  module = "code.linenisgreat.com/madder/go";
  go = "1.26";

  # Third-party modules: the version the go command selected, the NAR hash the
  # vendor tree fetches by, and the module's own Go language version.
  require = {
    "golang.org/x/tools" = { version = "v0.49.0"; hash = "sha256-…"; go = "1.24"; };
  };

  # Fleet modules (RFC 0001): the flake input IS the version. Rendered as a
  # require + replace pair; no pseudo-version is stored anywhere.
  flakeInputs = {
    "code.linenisgreat.com/tommy" = { input = "tommy"; };
    "code.linenisgreat.com/tap/go" = { input = "tap"; subPath = "go"; };
  };

  # Real replace directives, if any survive (forks, local overrides).
  replace = { };
}
```

- **Fleet modules name a flake input (decided 2026-09-14).** `flakeInputs`
  entries carry an input *name* and an optional `subPath`, not a source. The
  builder receives the flake's `inputs` and resolves each entry to
  `inputs.<input>.packages.${system}.go-pkgs` — the RFC 0001 producer
  convention, which therefore becomes mandatory for manifest consumers. Sources
  that do not follow it (igloo's path fixtures, an unusual producer) are
  supplied by a builder-side override instead of in `go.nix`:

  ```nix
  buildGoAuto { inherit pname src inputs; manifest = ./go.nix; }
  ```

- **Render** (pure, inside derivations): the manifest → a go.mod with the
  `module`, `go`, `require` and `replace` lines, plus the synthesized
  require/replace pairs for `flakeInputs`. This supersedes RFC 0001's eval-time
  merge of an organic go.mod: there is no organic go.mod to merge into.
- **Vendor tree**: built from `require`'s hashes (what gomod2nix.toml does
  now), so gomod2nix.toml folds into the manifest.
- **Package graph, derived at eval time**: `godyn-gen` runs inside a
  derivation against the rendered go.mod and the vendor tree, and godyn
  imports its output (import-from-derivation). There is **no committed
  graph.json**: the manifest plus the source tree are sufficient to derive the
  graph, so it cannot drift. The graph records each module's Go version, and
  godyn passes it as each package's `-lang`. It also records each
  package's **standard-library imports** (`stdImports`; graphs from an older
  `godyn-gen` omit them):
  the type-bearing vetx lanes (igloo#71) must supply a vetx for every import,
  and without that edge list they hand every package run the whole stdlib index
  (355 packages, ~4.9 MB read per run). With it, each run gets only the stdlib
  vetx files its package's imports actually reach.

## Decision: no committed graph

The manifest must be sufficient to derive the package graph at evaluation
time; consumers commit no graph.json. The cost is that eval-time builds are
per-system: evaluating another system's packages needs a builder for that
system. That limit is **accepted** — goFlakeInputs consumers already have it
today (spinclass's `packages.aarch64-darwin.default` cannot be evaluated from
an x86_64-linux host, because the RFC 0001 merge builds a per-system go-pkgs
derivation during evaluation). This supersedes the committed-graph workflow
and its drift check (igloo#72), which only matter until a consumer moves to a
manifest.

**Progress (igloo#72).** The eval-time half works today, ahead of the manifest:
with no `graphFile`, `buildGodynModule` derives the build graph — and, with
`tests = true`, the test graph — by running `godyn-gen` inside the
buildGoApplication sandbox from the existing go.mod and gomod2nix.toml
(merged go.mod for goFlakeInputs, vendored deps, offline). In that vendor mode
`go list` reports no module for vendored packages, so `godyn-gen` recovers each
one's module root and go directive from the vendored module's own go.mod. On
igloo's fixtures the derived graphs equal the ones `godyn-gen` produces in
module mode (checks `godyn-derived-graph-test`, `godyn-derived-tests-test`).
The stdlib-import edge list has landed too: graphs record each package's
`stdImports`, and a lint run is handed only the stdlib vetx its import closure
reaches — 61 of 355 for the cgo fixture's `main`, which imports `fmt`. 

**Progress (manifest, 2026-09-14).** `buildGodynModule` and `buildGoAuto`
accept `manifest = ./go.nix` (with `inputs` and `goFlakeInputOverrides`) in
place of `modules`, `goFlakeInputs` and a tracked go.mod
(`pkgs/build-support/godyn/manifest.nix`). igloo renders the go.mod and
gomod2nix.toml from the manifest, resolves `flakeInputs` through `inputs`,
and derives the graph from the rendered go.mod. A module that still tracks a
go.mod is rejected. The `godyn-manifest-test` check builds a fixture whose
tree has no go.mod (and no go.sum) with a third-party require and a flake
input on both backends. It confirms that the third-party module compiles at
its own go directive (`1.13`), and that go.mod → manifest → go.mod is
lossless for module, go, requires (including `// indirect`), fleet
require/replace pairs, and path, module and versioned replaces.
Comments other than `// indirect`, and `toolchain`, `godebug`, `exclude`,
`retract` and `tool`, are rejected by the go.mod → manifest direction.
**go.sum:** builds do not need it (vendor mode with `GOSUMDB=off`). Still
to come: the escape hatch (render into a derivation, `ingest`) and a fleet
consumer.

**Producers (2026-09-14).** `mkGoPkgs` accepts `manifest` (+ `inputs`,
`goFlakeInputOverrides`): a go.nix producer's `go-pkgs` outputs carry a
rendered go.mod (sentinel requires for its fleet modules, no replace) and
gomod2nix.toml, and its `flakeInputs` become `passthru.goFlakeInputs`, so
consumers bridge it unchanged whether or not they have cut over
(`godyn-producer-gonix-test`: organic consumer, both backends, producer
self-test; `godyn-producer-manifest-test`: go.nix consumer). This is what the
second tracer, a producer, needs before it drops go.mod.
**Rollout constraint (found bumping spinclass to tommy 3b9f688):** a
consumer that pins the producer's igloo to its own (`<producer>.inputs.igloo.follows
= "igloo"`, the fleet convention) evaluates the producer's `mkGoPkgs {
manifest; inputs; }` against the consumer's igloo, so bumping a cut-over
producer forces the consumer's igloo to at least the producer-capable rev
(899189e). Not a bug: the go.nix bridge itself is consumer-transparent; the
flake-level `follows` is not. Bump both together.

**Second tracer (2026-09-14): tommy, a producer.** tommy `3b9f688` cut
over — go.nix ingested with the previous hashes and per-module Go versions,
`mkGoPkgs { manifest; inputs; }`, go.mod/go.sum/gomod2nix.toml and `mkGoEnv`
removed, full gate green. spinclass `f48ce08` then bumped tommy (and igloo,
per the constraint above): its go.nix, builds, tests, lint, codegen drift
check and generated code were unchanged apart from the stamped tommy rev,
and its full gate stayed green. That is the consumer-transparency claim
verified on a live producer/consumer pair; the go.nix consumer count for
the experimental → testing gate is now two.

**Third tracer (2026-09-14): crap/go-crap, a subPath producer with a `/v2`
major.** crap `a4320ea`: go.nix ingested with every hash, per-module Go
version and indirect marker matching the old toml; `mkGoPkgs { manifest;
subPath = "go-crap"; }` (subPath added to igloo for it, `8b8cab2`); builds
on `buildGoAuto` from `go-pkgs-test + "/go-crap"` with the manifest; godyn
tests, vet and lint checks; `-race` needs `cc`; no ambient go left in the
devshell. The `/v2` chain agrees end to end: rendered module line
`…/go-crap/v2`, consumer sentinel `v2.0.0-00010101000000-000000000000`, and
the vendor symlink `code.linenisgreat.com/crap/go-crap/v2 → <go-pkgs>/go-crap`,
verified with a throwaway go.nix consumer on both backends. Consumer bumps
(spinclass, cutting-garden) follow.

## Goal: drop gomod2nix (decided 2026-09-14)

go.nix replaces gomod2nix as a consumer-facing tool: no gomod2nix.toml, no
`gomod2nix generate`, no `mkGoEnv` devshells, no drift linter. This does
not require dropping `buildGoApplication` as an internal builder (godyn's
vendor tree and graph derivation run inside it today).

## Tracer bullet: spinclass (decided 2026-09-14)

spinclass is the first consumer, and every part of it that depends on a
committed go.mod gets a **first-class godyn solution, with an igloo fixture,
before spinclass is asked to cut over**. Inventory from the spinclass session
(spinclass/brave-catalpa/pennywise, 2026-09-14); items marked *theory* are
unverified:

| spinclass dependency | godyn solution | status |
|---|---|---|
| builds: `modules` + `goFlakeInputs` at the bga and godyn sites, race/madder/native variants, ldflags pins, version.env, postInstall | `manifest` on `buildGodynModule` / `buildGoAuto` | landed (`godyn-manifest-test`); `race = true` on both backends landed (`godyn-manifest-tests-test`); ldflags/version.env/postInstall are manifest-independent |
| `checks.spinclass`: `go test ./...` via bga with runtime check inputs (git, a CLI) | godyn per-package tests from a manifest (`tests = true`, `nativeCheckInputs`) | landed (`godyn-manifest-tests-test`: the test graph derives from the rendered go.mod, the test links the fleet and third-party modules) |
| `checks.lint`: `buildGoLint` on the bga base | godyn lint and vet lanes from a manifest | landed (`godyn-manifest-lint-test`, `godyn-manifest-vet-test`); the suite is godyn-lint's, not golangci-lint's (godyn(7) § LINT) |
| codegen drift check (`verify-tommy-codegen` in the merge gate) | a **pure** check: run the generator against the rendered module, diff against committed output | landed: `passthru.codegenCheck { command; nativeBuildInputs; exclude; }` runs the command in the vendored module tree and fails on any diff from `src` (`godyn-manifest-codegen-test`, `godyn-manifest-codegen-drift-test`); the tommy invocation itself is spinclass's to wire |
| inner loop: fast, cached `go test <pkg>` on the dirty tree (`debug-go-test`) | **decided 2026-09-14:** a godyn command that builds one package's test run from a `git+file:` flake ref of the dirty tree (tracked files as in the working tree; a new file after `git add -N`; `.git` and `.tmp` never copied), with per-invocation test flags; only the edited cone rebuilds | `passthru.testWith` landed (`godyn-test-with-test`); measured on the gotest fixture (`explore-godyn-test-loop`, x86_64-linux, one host): no-op floor ~4.4 s, a `_test.go` edit or a new untracked test file ~6.6–7.4 s (both graphs re-derived, test binary rebuilt, run). The floor is evaluation plus the tree copy. The `godyn-test` CLI wraps it (prints the log, exits by result) |
| `go generate` / `go get` / `go mod tidy` writing back | escape hatch + `ingest` | landed: `passthru.goRun` (impure derivation), `passthru.ingest`, the `godyn-go` CLI; verified on the manifest fixture (`go get` bump ingested end to end, `explore-godyn-go`); the pure half is checked (`godyn-manifest-ingest-test`) |
| agent `go doc` (hamster) through the module (*theory*) | first-class answer needed | open |
| conformist: eng-versioning reads go.mod's module path, tommy codegen repair hook type-loads packages, gofumpt reads the go directive (all *theory*) | go.nix-aware equivalents; conformist/tommy lanes to confirm | open |
| devshell `mkGoEnv` + gomod2nix CLI | retired | spinclass's devshell dropped both (cutover below); igloo keeps them until every consumer has (testing → accepted) |
| migration: go.mod + gomod2nix.toml → go.nix | `godyn-go -I <dir>` over a seed go.nix (module, go, flakeInputs) | landed (`godyn-manifest-migrate-test`: fleet requires and relative replaces drop, third-party hashes carry over; verified on a fixture with the CLI) |

Ordering constraint: spinclass's own merge gate runs its codegen recipes, so
the replacements land before spinclass removes go.mod.

**Cutover (2026-09-14, promoted to experimental).** spinclass landed
`13d42af` + `104a5a0` on its default branch: go.mod, go.sum, gomod2nix.toml
and its gomod.nix removed, go.nix in their place (seeded with module, go and
four `flakeInputs`, then `godyn-go -I .`), both `buildGoAuto` sites on
`manifest`, tests/vet/lint/codegen as flake checks, `build-tommy-codegen`
through `godyn-go`, `debug-go-test` on `godyn-test`, `mkGoEnv` and gomod2nix
out of the devshell. Its full `just` gate passed in the merge run on igloo
`c0dfbe9`, conformist `7e1bac4` (go.nix-aware eng-versioning and gofumpt) and
tommy `5767957` (generator proven inside `codegenCheck`). Known gaps
recorded in that commit: four `serve_integration` tests skip under godyn (no
`go` on PATH; bga's checkPhase in the bats lanes still runs them); godyn-lint
replaces the golangci-lint set on x86_64-linux; three debug recipes still
need ambient `go`; gopls, delve and gotools stay in the devshell with nothing
to work against; the unit suite runs more than once per `nix flake check`.
Measured inner loop on spinclass (`internal/perms`, `git+file:`): ~2.5 s
no-op, ~6 s after a test edit.

## Escape hatch: go commands against the rendered module

The go toolchain outside nix is unsupported, but dependency changes
(`go get`, `go mod tidy`) and source generators still need a go.mod. The
escape hatch runs those commands **inside nix**, against a go.mod and go.sum
rendered into a derivation — never into the checkout — and moves results back
with a **lossless, two-way conversion** between go.mod and the manifest:

- **`render`** produces the manifest's go.mod and go.sum inside a derivation
  (fleet modules, declared and inherited, replaced to their go-pkgs store
  paths). They are build inputs, never files in the checkout.
- **`ingest`** reads a go.mod changed by `go get` / `go mod tidy` and writes
  the differences back into the manifest — new or bumped requires (with their
  hashes, fetched in nix), dropped requires, a changed `go` line.

Tooling this has to serve (fleet survey, 2026-09-14):

- **Dependency management** (network): `go get`, `go mod tidy`,
  `go mod download`, `go work`; `gomod2nix generate` is replaced by `ingest`.
- **Generators that rewrite checked-in source**: `go generate` driving
  `tommy generate`, `dagnabit export`, `stringer`, `enumer`, and `go run`
  generators (langlang).
- **Ad-hoc `go test` / `go run` / `go build` / `go vet` / `go list`** in
  justfile recipes, and **analysis needing network** (`govulncheck`).
- **Lint and format hooks**: golangci-lint and goimports need package
  loading; gofumpt works per file.
- Out of scope: godyn-gen graph recipes, which the eval-time graph retires.

**Direction (2026-09-14):** a consumer-exposed command
(`nix run .#go -- <cmd>`) builds an **impure derivation** (`__impure = true`:
network allowed, never cached) whose source is the checkout plus the rendered
go.mod and go.sum, runs the command with the pinned toolchain and tools, and
outputs a patch against the input source (plus the changed go.mod). The
wrapper applies the patch to the checkout and runs `ingest`. `--impure` alone
does not give a build network access. Costs: impure derivations are an
experimental Nix feature every host must enable (`impure-derivations`,
which needs `ca-derivations`); each run copies the checkout into
the store and starts with an empty module cache; the build has no SSH agent
or git credentials; generators that shell out to non-Go tools must declare
them.

**Landed (2026-09-14).** `passthru.goRun { command; nativeBuildInputs; }` is
the impure derivation; `passthru.ingest <out>` renders go.nix from its go.mod
and gomod2nix.toml (`gomod2nix generate` runs inside the derivation, so it
records the hashes and each module's Go version); `godyn-go` wraps both
(godyn(7) § The escape hatch). On this host `go get` against the manifest
fixture reached the proxy from inside the sandbox, wrote go.sum with the
checksum database on, and the bump came back as a well-formed go.nix. The
rendered go.nix is nixfmt-stable (`godyn-manifest-ingest-test` diffs it
against a committed, formatter-checked copy), so consumers need not exclude
go.nix from their nix formatter (raised by conformist/fresh-willow, 2026-09-14).
**Measured (`explore-path-ref-contents`, `explore-godyn-test-loop`):** a
`path:` flake ref of a checkout copies **everything** into the store —
`.git` and the git-ignored `.tmp` included (igloo's worktree: 203 MB, 171 MB
of it `.tmp`) — and re-copies on every edit; that copy is most of the inner
loop's ~4.4 s no-op floor. A `git+file:` ref of the same dirty tree copies
only tracked files (modified contents included) and floors at ~1.0 s on the
same fixture; a new file is included once it is `git add -N`'d (verified).
**Decided 2026-09-14:** `godyn-go` and `godyn-test` build from `git+file:`
(fast, `.tmp`-free; a new file needs `git add -N`, the fleet's existing
`nix build` convention), not `path:`.

Rules the pair must keep:

- **Round-trip stability**: `render ∘ ingest ∘ render` = `render`. Anything the
  manifest does not own (comments, `toolchain`, `godebug`, `retract`,
  `exclude`) is either modeled or rejected by `ingest` with a clear error —
  never silently dropped.
- **The manifest wins**: a rendered go.mod that disagrees with the manifest is
  regenerated, not trusted. Only an explicit `ingest` moves information from
  go.mod back into nix.
- **Fleet modules stay flake inputs**: `ingest` maps a require on a fleet
  module back to its `flakeInputs` entry instead of recording a version.
  A fleet module the manifest does not declare but a declared producer
  bridges (an **inherited** bridge, RFC 0001 depth-N) may still appear as a
  versioned third-party require after a migration or a `go get`: harmless.
  The merge keeps the require's version line but replaces the module to the
  inherited bridge and strips it from the vendor table, so its version and
  hash are dead data and the bridge wins on both backends
  (`godyn-producer-manifest-test`, whose hash is bogus). This matches the
  organic-require case before go.nix. A fleet module that **no** producer
  bridges (spinclass's tap/go: tommy consumes tap only as a binary, not as a
  Go bridge) is simply a third-party require fetched from the proxy, before
  and after go.nix — declare it under `flakeInputs` only if the flake gains
  that input.

Both directions build on existing pieces: gomod2nix already parses go.mod in
nix (the `parser-*-test.nix` fixtures), and RFC 0001's merge already renders
directives into a go.mod.

**Decided 2026-09-14:**

- **The tool is a thin wrapper over nix** (`godyn-manifest`). The
  conversion logic lives only in `manifest.nix` (`fromGoMod`, `renderGoMod`),
  which the round-trip check covers. `ingest` takes hashes and per-module Go
  versions from `gomod2nix generate`, then prints go.nix from nix.
- **Nothing is rendered into the checkout.** go.mod and go.sum exist only in
  derivations; `ingest` drops store-path replaces from a changed go.mod
  (fleet bridges), never recording them.
- **gopls and dlv are unsupported.** Interactive tools cannot run inside a
  build, and nothing is rendered into the checkout for them. A POC for native
  support may revisit this (Future Work).

## Open Questions

- **Eval-time graph mechanics.** Answered (igloo#72, 2026-09-14): `godyn-gen`
  runs in a `buildGoCheck` over `buildGoApplication` — merged or rendered
  go.mod, vendor tree, offline, for the evaluating system, cgo only with a
  `cc` — and its JSON is imported at eval time (import-from-derivation);
  `tests = true` adds `-test-deps` to the build graph and derives the test
  graph with `-tests`. Covered by `godyn-derived-graph-test`,
  `godyn-derived-tests-test` and `godyn-manifest-test`. The cross-system
  evaluation limit is accepted above and tracked as igloo#75.
- **Does go.sum survive?** Answered (2026-09-14): no. Vendor-mode builds and
  `godyn-gen` need none, so the manifest carries NAR hashes only. The escape
  hatch runs `go mod download` inside its impure derivation before the
  command, which writes go.sum with `GOSUMDB` left on (sums checked against
  the checksum database); `ingest` ignores go.sum. Builds still verify NAR
  hashes.
- **Where does version selection run?** Answered: inside the escape hatch's
  impure derivation, not an ambient go.
- **Workspaces.** Answered (2026-09-14): **one go.nix per module**, no
  workspace concept. Each go.work member gets its own manifest and references
  its siblings as path replaces, and go.work is retired. The only fleet
  workspace today is purse-first (`.`, `libs/dewey`, `libs/go-mcp`,
  `libs/go-mcp/command/huh`, one shared gomod2nix.toml). Cost: the shared
  lockfile splits — third-party requires and hashes repeat per member, and
  members can drift to different versions. Unverified: that the derived graph
  and vendor tree handle sibling path replaces when `src` is the repository
  root; igloo#73 becomes that fixture.
- **Escape-hatch output.** Answered (2026-09-14): the derivation's source is
  the checkout's tracked files as in the working tree, without `.git` or
  ignored directories (a new file after `git add -N`). It outputs
  `git diff --no-index --binary` of that source against the result —
  excluding go.mod and go.sum — plus the changed go.mod. The wrapper runs
  `git apply --check` then `git apply` (edits, new and deleted files, binary
  files) and `ingest` on the go.mod. If a file the patch touches changed in
  the checkout meanwhile, nothing is written and the wrapper prints the
  patch's store path; edits to untouched files are unaffected. No three-way
  merge.

## Limitations

- **No editor or debugger support.** gopls and dlv are unsupported: the
  checkout has no go.mod, and the escape hatch runs only batch commands. That
  is the intended cost of "no toolchain outside nix" until a native-support
  POC says otherwise.
- **Migration**: every consumer converts its go.mod once (`godyn-go -I` is the
  migration tool) and stops editing go.mod directly. go.nix is rewritten as
  plain sorted data on every ingest, so comments in it do not survive.
- **Third-party Go versions** have to be recorded per module (from each
  module's own go.mod, at ingest time) to fix per-package `-lang`.

## Future Work

- **Optional Nix evaluator plugin for godyn (flagged 2026-09-13).** The
  eval-time graph stays import-from-derivation by default. A plugin (as numtide
  go2nix's `builtins.resolveGoPackages`) could later resolve the graph inside
  the evaluator — faster evaluation and no cross-system IFD limit (igloo#75) —
  for hosts that opt in. It cannot be the default: a flake or overlay cannot
  load it (`plugin-files` is host config) and it is bound to one Nix version
  (FDR 0001). Keeping `godyn-gen`'s graph JSON as the interface lets the
  derivation and a plugin share one resolver.
- **Building Nix-version-bound plugins** is shared with rustdyn: see FDR 0009
  § Future Work.
- **Native gopls and dlv support (descoped 2026-09-14).** A POC could find a
  way to serve them without a checkout go.mod — for example the rendered
  module plus `-modfile` (which still requires a placeholder go.mod to locate
  the module root), or a gopls launched from a derivation.

## More Information

- FDR 0007 (`docs/features/0007-godyn-only-go-builds.md`) — godyn as the only
  Go build path; this FDR changes where its dependency inputs come from.
- RFC 0001 (`docs/rfcs/0001-flake-input-go_mod.md`) — the fleet-module
  protocol; `flakeInputs` here is its consumer half without an organic go.mod.
- FDR 0006 § *Why not fix the devshell?* — why a checkout-side go.mod cannot
  be supplied purely; the escape hatch avoids one by running commands inside a
  derivation.
- Issues: igloo#72 (graph drift), igloo#73 (go.work consumers).
