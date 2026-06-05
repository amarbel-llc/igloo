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
- **D6 native** — the same `internal/delta` closure via godyn-v2's *eval-time*
  graph (`.#dewey-delta-native`, `../godyn-v2/native.nix`; no recursive-nix), for
  the real-scale head-to-head. ✅ `just bench-delta` (native vs recursive vs a bga
  whole-subtree proxy): native is **4–5× the resolver** and **7–13× bga** on
  edits at 74 packages (rebuilds the 1–30-package cone, not the whole subtree).
  tommy is **vendored** here (apples-to-apples with bga), not bridged. Full
  analysis: `../godyn-v2/README.md` § Real-scale validation.

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

FOD scope (#24) is now fixed on **both** paths — only the modules the
`internal/delta` graph imports are fetched, not the whole lockfile/workspace:

- **native** (`.#dewey-delta-native`): `just gen-scoped-toml` scopes the gomod2nix
  toml to the graph, so its vendorEnv pulls only the **11** modules (from 89
  workspace modules).
- **recursive** (`.#dewey-delta`): `just gen-scoped-lock` scopes the resolver
  lockfile to a `dewey-delta.lock` of **10** modules (from 55; the 11th, tommy, is
  bridged, not a lockfile FOD). Viability confirmed — `go list -deps` succeeds with
  the partial GOMODCACHE (Go module-graph pruning). `deweySeqerror`/`deweyAll` keep
  the full `dewey.lock` (wider scopes).

Both outputs are byte-identical to the over-fetching builds (the build only ever
read the in-scope modules). The drops (89→11, 55→10) are recorded in the versioned
benchmark (`just bench-record` / `just bench-history`). The remaining throughput
cost is the `path:` worktree input re-copying `.tmp` on every eval (~24s warm
floor) — separate from FODs.

### godyn vs `buildGoApplication` — the nix builder it would replace

This is the comparison that matters: both are hermetic nix builds.
`buildGoApplication` (gomod2nix) builds a binary as **one** derivation — external
deps cached (`go-cache-env`), but the module's own packages recompile on every
source change, because nix has no per-package granularity inside the build. Same
binary (`seqerror`), built both ways, editing the same `cmd/seqerror/main.go`:

| scenario | `buildGoApplication` | godyn |
|---|---|---|
| cold | 34 s | 43 s¹ |
| warm (no change) | **0 s** (derivation cached) | 38 s → **1–2 s**³ |
| comment edit | **24 s — full closure rebuild** | 52 s → **9 s**³ / **1 pkg** |
| semantic edit | **23 s — full closure rebuild** | 39 s → **8 s**³ / **1 pkg** |

¹ godyn reused most of seqerror's closure from the earlier `.#dewey-all` build —
cross-target CA sharing, only 26 packages were fresh. ² with the original `path:`
igloo input. ³ after switching the igloo input from `path:` to `git+file:` — see
below.

**The overhead was the whole story.** The `path:` igloo input re-copied the entire
worktree — including the gitignored **~2.6 G** `.tmp` clone — to the store on every
eval (~38 s). Switching it to `git+file:` (git-tracked files only) collapses that
to ~1–2 s, and the comparison **flips**:

- warm (no change) → ~1–2 s: nix's digest matching returns the cached graph with
  **0 rebuilds** — the merkle effect working at the leaf level. (Identical content
  across an edit→revert cycle is deduped by the CA store too: revert an edit, or
  rebuild a change someone else already built, and it's instant.)
- edit (genuinely new content) → **8–9 s, exactly 1 package recompiled**, now
  **beating** `buildGoApplication`'s 23–24 s whole-closure rebuild.

So per-package CA delivers on both axes once the overhead is gone: it rebuilds only
the dependency cone (comment-level early cutoff; outputs binary-cache-substitutable
across machines *and* build targets) **and** wins wall-clock. The residual ~8 s is
the resolver re-running over the full graph (re-register + cache-check all 38
packages to rebuild 1) — the monolithic-wrapper cost #26 tracks; nix's scheduler
should skip that unchanged subgraph natively (it does — see the D6 native build).
The FOD over-fetch (#24) is now **scoped on both paths** (native 89→11 via
`gen-scoped-toml`, recursive 55→10 via `gen-scoped-lock`).

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
