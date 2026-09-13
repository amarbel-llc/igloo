---
status: exploring
date: 2026-09-11
promotion-criteria: |
  exploring → proposed: the manifest shape below is settled on one
  fixture: igloo renders a go.mod from it inside a derivation, derives
  the fixture's package graph from it at eval time (no committed
  graph.json), and godyn builds the fixture with no go.mod in the source
  tree; the round trip go.mod → manifest → go.mod is lossless for every
  field the manifest owns.

  proposed → experimental: the bidirectional tool exists — `render`
  writes a go.mod (and go.sum, if still needed) for editors, `ingest`
  folds a go.mod edited by `go get` / `go mod tidy` back into the
  manifest — and one fleet consumer (spinclass) builds, tests, vets and
  lints from its manifest with its committed go.mod removed.

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

A nix file in the module root — the name (`go.nix`, `module.nix`) is open —
evaluating to an attrset. Everything below is a sketch to be settled by the
first fixture:

```nix
{
  module = "code.linenisgreat.com/spinclass";
  go = "1.26";

  # Third-party modules: the version the go command selected, the NAR hash the
  # vendor tree fetches by, and the module's own Go language version.
  require = {
    "golang.org/x/tools" = { version = "v0.49.0"; hash = "sha256-…"; go = "1.24"; };
  };

  # Fleet modules (RFC 0001): the flake input IS the version. Rendered as a
  # require + replace pair; no pseudo-version is stored anywhere.
  flakeInputs = {
    "code.linenisgreat.com/tommy" = "tommy"; # names a flake input
  };

  # Real replace directives, if any survive (forks, local overrides).
  replace = { };
}
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
reaches — 61 of 355 for the cgo fixture's `main`, which imports `fmt`. Still to
come: the manifest and its render step, which replace go.mod and
gomod2nix.toml as the inputs.

## Editor escape hatch: bidirectional go.mod ↔ manifest

The go toolchain outside nix is unsupported, but editors (gopls) and the
occasional `go get` still need a go.mod on disk. The escape hatch is a
**lossless, two-way conversion** between go.mod and the manifest:

- **`render`** writes the manifest's go.mod (and go.sum, if needed) into the
  checkout for gopls and ad-hoc `go` use. The written files are generated
  artifacts: gitignored, never authoritative, safe to delete.
- **`ingest`** reads a go.mod changed by `go get` / `go mod tidy` and writes
  the differences back into the manifest — new or bumped requires (with their
  hashes, fetched in nix), dropped requires, a changed `go` line.

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

## Open Questions

- **Eval-time graph mechanics.** `godyn-gen` must run offline in the sandbox
  (against the vendor tree), per system (GOOS/GOARCH), and for the test graph
  (`-tests`); how the resulting JSON is imported at eval time is to be settled
  on the first fixture.
- **Does go.sum survive?** If `godyn-gen` and every other in-nix go command run
  against the vendored tree (`-mod=vendor`), the go command does not verify
  go.sum, and the manifest can carry NAR hashes only. Unverified for
  `go list -deps`; if it fails, the manifest carries `h1:` sums too and
  renders a go.sum.
- **Where does version selection run?** `go get` / `go mod tidy` perform
  minimal version selection and need the network. Under the "no toolchain
  outside nix" rule they run from a nix-provided command (a `just` recipe, or
  part of `render`/`ingest`), not an ambient go.
- **Workspaces.** How a manifest expresses go.work-style multi-module setups
  (igloo#73).
- **Name and location** of the manifest file, and whether it is plain nix or
  a data format (TOML) nix reads.

## Limitations

- **Editors depend on `render`.** Without a rendered go.mod, gopls has no
  module; that is the intended cost of "no toolchain outside nix", paid down
  by the escape hatch.
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

## More Information

- FDR 0007 (`docs/features/0007-godyn-only-go-builds.md`) — godyn as the only
  Go build path; this FDR changes where its dependency inputs come from.
- RFC 0001 (`docs/rfcs/0001-flake-input-go_mod.md`) — the fleet-module
  protocol; `flakeInputs` here is its consumer half without an organic go.mod.
- FDR 0006 § *Why not fix the devshell?* — why a checkout-side go.mod cannot
  be supplied purely; the render escape hatch accepts generated files instead.
- Issues: igloo#72 (graph drift), igloo#73 (go.work consumers).
