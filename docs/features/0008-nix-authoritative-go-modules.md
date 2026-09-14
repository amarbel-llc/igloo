---
status: proposed
date: 2026-09-14
promotion-criteria: |
  exploring → proposed: the manifest shape below is settled on one
  fixture: igloo renders a go.mod from it inside a derivation, derives
  the fixture's package graph from it at eval time (no committed
  graph.json), and godyn builds the fixture with no go.mod in the source
  tree; the round trip go.mod → manifest → go.mod is lossless for every
  field the manifest owns.

  proposed → experimental: the escape hatch exists — go commands
  (`go get`, `go mod tidy`, `go generate`) run in an impure derivation
  against the go.mod and go.sum rendered there, their changes are applied
  back to the checkout, and `ingest` folds a changed go.mod into the
  manifest — and one fleet consumer (spinclass) builds, tests, vets and
  lints from its manifest with its committed go.mod removed. gopls and dlv
  are out of scope.

  experimental → testing: dependency updates happen only through the
  manifest (directly or via ingest) on at least two consumers; each
  third-party module's own Go language version reaches its compiles.

  testing → accepted: a release cycle with no consumer re-committing an
  authoritative go.mod, and gomod2nix.toml retired for manifest
  consumers.
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
  the checkout without `.git` (untracked files included). It outputs
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
- **Migration**: every consumer converts its go.mod once (`ingest` is also the
  migration tool) and stops editing go.mod directly.
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
