# godyn-dewey — per-package builder on a real fork module (cgo + tags + bridge)

Real-world validation of the godyn per-package Go builder (see `../godyn-poc/`)
against a real fork module — dewey
(`github.com/amarbel-llc/purse-first/libs/dewey`) — exercising the three things
the toys skipped: **cgo** (dewey → `DataDog/zstd`), **build tags**, and the
**flake-input bridge** (`github.com/amarbel-llc/tommy` from its `go-pkgs` output).
Plus a dewey inlining-density measurement.

The dewey/purse-first source is a gitignored clone under
`/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany/.tmp/purse-first`
(cloned to avoid cross-worktree permission prompts); only this README + recipes
are tracked.

## Milestones

- **D0 measure** — dewey inlining density. ✅ (below)
- **D1 lockfile** — generate the godyn lockfile from purse-first's
  `gomod2nix.toml` (SRI NAR hashes) + dewey's `go.sum` (h1). ✅ (`dewey.lock`, 55 modules)
- **D2 tags** — thread build tags through `go list`. ✅ (`../godyn-poc` `.#tags-off`/`.#tags-on`)
- **D3 cgo** — compile + link a zstd consumer. ✅ (`../godyn-poc` `.#cgo`)
- **D4 bridge** — source tommy from its `go-pkgs` (replace → store path). ✅ (`../godyn-poc` `.#bridge`)
- **D5 full** — build dewey packages via godyn. ✅ scoped to `./internal/delta/...`
  (`.#dewey-delta`); full `./...` deferred (see below).

### D2–D5: `.#dewey-delta` — 74-package build of `dewey/internal/delta/...`

`nix build .#dewey-delta` builds dewey's `internal/delta/...` subtree (18 dewey
packages; 74-package non-stdlib closure) through the godyn resolver, exercising
**all four features at once on real fork code**: cgo (`compression_type` →
`DataDog/zstd`), the tommy **bridge** (`script_config`/`tommy_util` →
`tommy/pkg/cst`,`pkg/document` from tommy's `go-pkgs`), 36 third-party modules
from `dewey.lock`, and **Plan 9 assembly** (`golang.org/x/sys/unix`). It has no
`main`, so it builds **compile-only** (a manifest derivation that realises every
archive). Resolver gaps closed to get here:

- **Plan 9 `.s` asm** — third-party packages with hand-written syscall asm
  (`x/sys/unix`) are pervasive in dewey's closure. Added a `go tool asm` path
  (gensymabis → compile with `-symabis`/`-asmhdr` → assemble → pack), captured
  from `go build -x`.
- **per-package importcfg scoping** — each compile drv now gets only its
  *transitive* imports, not the whole compiled set, so an edit to one package
  doesn't perturb every later drv's inputs.

### Incremental rebuild / cache isolation (the per-package CA payoff)

Same `.#dewey-delta` target, measured back-to-back:

| build | wall | compile re-runs | note |
|---|---|---|---|
| cold (first after a resolver change) | ~47s | 65 / 74 | importcfg reshaped once |
| warm (no source change) | ~24s | **0 / 74** | wrapper fully cached; the ~24s is nix re-copying the `path:` worktree input each eval |
| edit one tier-0 package (`internal/0/interfaces`, 29 dependents) | ~57s | **27 / 74** | `interfaces` + its real dependents only; **47 packages stay cached** |

So a change to a foundational package rebuilds **only its dependency cone** — every
third-party module (`age`, `charmbracelet/*`, `zstd`, `x/sys`) and every unrelated
dewey package is reused from the CA store. A **comment-only** edit to the same
package rebuilds just that one archive and then **early-cuts off entirely** (the
recompiled `.a` is byte-identical, so no dependent re-runs) — the CA property R6
predicted, now observed end to end on a real module.

### Full `./...` — `.#dewey-all`

`nix build .#dewey-all` builds **every** dewey package: a **273-package**
non-stdlib closure (169 dewey own + the full ~40-module dep stack: charmbracelet
TUI, `filippo.io/age` crypto + its own asm, `gopher-lua`, `mvdan.cc/sh`, the 4
analyzer `cmd` mains). It has mains, so it compiles all 273 and **links one
binary** — a working `seqerror` analyzer (10 MB) that runs and prints its usage.
No new source-kind gaps surfaced across the whole closure. Wall time **~75s**
with the stdlib + FODs + `internal/delta` subtree already warm (so ~199 fresh
compiles; ~0.4 s/pkg).

Known throughput costs (not capability gaps): the resolver fetches *all* 55
lockfile FODs up front regardless of scope, and the `path:` worktree input
re-copies `.tmp` on every eval (the ~24s warm floor).

### godyn vs `buildGoApplication` — the nix builder it would replace

This is the comparison that matters: both are hermetic nix builds.
`buildGoApplication` (gomod2nix) builds a binary as **one** derivation — external
deps cached (`go-cache-env`), but the module's own packages recompile on every
source change, because nix has no per-package granularity inside the build. Same
binary (`seqerror`), built both ways, editing the same `cmd/seqerror/main.go`:

| scenario | `buildGoApplication` | godyn |
|---|---|---|
| cold | 34 s | 43 s¹ |
| warm (no change) | **0 s** (derivation cached) | 38 s² |
| comment edit | **24 s — full closure rebuild** | 52 s wall / **1 pkg** recompiled |
| semantic edit | **23 s — full closure rebuild** | 39 s wall / **1 pkg** recompiled |

¹ godyn reused most of seqerror's closure from the earlier `.#dewey-all` build —
cross-target CA sharing, only 26 packages were fresh. ² almost entirely the
POC's `path:` worktree re-copy each eval (see below); the resolver is cached.

**The honest result — two things are true at once:**

- godyn rebuilds the **right set**: editing `main` recompiles exactly 1 package
  (main has no dependents). `buildGoApplication` recompiles seqerror's whole
  closure whether you touch a comment or a function — comment = semantic = 24 s,
  no granularity, no early cutoff.
- ...but godyn's **wall-clock is worse here** (52 s vs 24 s), because its
  per-invocation overhead — dominated by the `path:` worktree re-copy (~38 s),
  plus a `nix build` daemon round-trip per package — exceeds the cost of
  `buildGoApplication` simply rebuilding this small closure.

So per-package CA is the correct **shape** (rebuild only the dependency cone, with
comment-level early cutoff, and outputs that are binary-cache-substitutable across
machines *and* across build targets), but it only becomes a wall-clock **win**
once the rebuild it avoids exceeds godyn's fixed overhead. For dewey's small
analyzer closures, `buildGoApplication` wins today. The overhead is the thing to
kill — the `path:` re-copy (POC artifact) and the all-55 FOD over-fetch are the
two biggest levers; the daemon-round-trip-per-package is the structural one
numtide's in-process resolver avoids. Until those land, the shape is right but the
clock is not.

(For reference, native `go build` — non-hermetic, in-process content cache — is
the speed-of-light baseline at ~50× under either nix builder: with the **real**
user cache nuked, cold 31 s / warm 97 ms / edit-cone 863 ms / comment 102 ms.)

## Findings

### D0: dewey inlining density (go 1.26, dewey @ working tree 2026-06)

Method: `.#defererr.passthru.vendorEnv` materialised into the cloned workspace +
`GO_NO_VENDOR_CHECKS=1 GOFLAGS=-mod=vendor go build -gcflags=-m ./libs/dewey/...`
(CGO off, so `internal/delta/compression_type` → zstd fails last; the rest is
complete).

- **2,901 inlinable functions; 6,926 inlined call sites** (dewey is ~half
  dodder's 14,236).
- **Same pattern as dodder** — the fork's own generic collections dominate:

  | source | sites | kind |
  |---|---|---|
  | `collections_slice` | 814 | dewey generic container |
  | `collections_value` + `Slice[...]` + `Flag[...]` instantiations | ~640 | dewey generic containers |
  | `jen` (dave/jennifer), `lua` (gopher-lua), `types` (go/types) | ~1,010 | third-party codegen / analysis libs |
  | `errors`, `fmt`, `strings`, `atomic`, `time`, `slices`, `sync`, `bytes`, `reflect`, … | ~2,000 | stdlib |

**Interpretation.** dewey confirms the dodder result *generalizes across the
fork*: heavy reliance on generic collection types (`collections_*`) whose methods
inline pervasively into nearly every consumer. So the per-package CA cache win is
the same shape everywhere — real for high-layer edits, bounded for foundational
generic edits — and the `-gcflags=all=-l` inlining-off variant is a fork-wide
lever, not a dodder quirk.
