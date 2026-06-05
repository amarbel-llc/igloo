# godyn v2 tracer bullet — eval-time native graph vs recursive-nix resolver

A thin end-to-end slice answering one question: **what is the payoff of moving
the per-package Go build graph from build-time (a recursive-nix resolver that
re-runs on every edit) to eval-time (one plain nix derivation per package, wired
by `inputDrvs`, scheduled by nix itself)?** This is task **#26**.

The same minimal module is built three ways and the edit loop is measured head
to head:

- **A — native eval-time graph** (the new work): `gen/` runs `go list -deps
  -json` and commits `graph.json`; `native.nix` turns it into one
  content-addressed `mkDerivation` per package, each interpolating its deps'
  store paths into its importcfg so **nix records the inter-package edges as
  `inputDrvs`**. No recursive-nix, no dynamic-derivations, no resolver — nix's
  scheduler sees the whole DAG and rebuilds only changed nodes.
- **B — recursive-nix resolver** (`../godyn-poc`, unchanged): the current
  build-time resolver, which re-`go list`s + re-registers every package drv on
  each build.
- **baseline — `buildGoApplication`**: the nix whole-module builder.

The module is a deliberately tiny pure-Go hierarchy (no third-party / cgo / asm /
bridge — all already proven in the v1 dewey POC) so the comparison isolates the
*architecture*:

```
example.com/godyntb
  internal/leaf  (stdlib only; the bottom)  <- internal/mid <- internal/top <- main
```

## Results — reliable JSON benchmark (`just bench`)

`just bench <toy|tommy> [runs]` emits structured JSON (per approach × scenario:
min/median wall-ms over N runs + rebuilt-package count); `just bench-md` renders
the table below. This consistent multi-run harness (a unique edit token per run)
**supersedes the earlier single-run table** — which was unreliable and reported
native as the winner; it is not.

Two modules: the 4-package toy, and **tommy's pure-Go library** (7 packages, a
real `github.com/amarbel-llc/tommy` snapshot: `ringbuf → lexer → cst → document →
marshal`, + `formatter`). Median ms · packages nix recompiled:

| module · scenario | `buildGoApplication` | native (eval graph) | recursive (resolver) |
|---|---|---|---|
| toy(4) · warm | **375**·0 | 1022·0 | 420·0 |
| toy(4) · edit-bottom (cone 4) | **1427**·4 | 2310·4 | 4650·0¹ |
| toy(4) · edit-mid (cone 2) | **983**·2 | 2097·2 | 4663·0¹ |
| toy(4) · comment-bottom | **1178**·2 | 1737·1 | 5559·0¹ |
| tommy(7) · warm | **414**·0 | 937·0 | 457·0 |
| tommy(7) · edit-bottom (cone 6) | **1598**·6 | 2721·6 | 5002·0¹ |
| tommy(7) · edit-mid (cone 4) | **1321**·5 | 2473·4 | 4985·0¹ |
| tommy(7) · comment-bottom | **820**·1 | 1917·1 | 6148·0¹ |

¹ recursive's per-package compiles run nested inside the recursive-nix wrapper, so
the outer `-L` can't count them — wall-clock is the metric there.

### What this shows (honest, and not what the first toy run suggested)

1. **native beats the recursive resolver on every edit (~1.8–2×)** at both sizes —
   the **#26 payoff is solid**: the eval-time graph lets nix's own scheduler do the
   merkle-delta with no resolver re-run.
2. **but `buildGoApplication` beats native at this scale.** Its single
   `go build ./...` derivation has far less overhead than N per-package CA
   derivations (each its own build sandbox + CA hash) when the cone ≈ the whole
   module. At 7 packages the edit-bottom cone (6) is nearly the whole (7), so
   native does barely less *work* yet pays per-derivation overhead ×6, plus a ~1 s
   fixed eval cost (constructing N derivations) that the single bga derivation
   doesn't.
3. **the crossover where per-package beats bga needs LARGER modules.** At 197
   packages (the godyn-dewey `seqerror` build, `../godyn-dewey`) the *recursive*
   resolver already beat bga on edits (8 s vs 24 s) — the cone there (~3 local
   pkgs + main) is tiny against the 197-package whole. Since native beats recursive,
   native would beat bga there too. So the crossover lands **between 7 and 197
   packages**; pinning it is the next experiment (full tommy `./...` ≈115 pkgs via
   the vendorEnv path, already supported in `native.nix`/`gen`).

Per-package CA is the right **shape** (only the cone rebuilds; a comment early-cuts)
and beats the recursive resolver **always** — but it is a wall-clock **win over
buildGoApplication only once the module is large enough** that the avoided
whole-module rebuild outweighs N × per-derivation overhead. toy/tommy are below
that crossover; seqerror is above it.

## Crossover sweep — the axis is edit *locality*, not module size

`just sweep "5 10 25 50 100" 2` (see `sweep.sh`) generates synthetic "wide-star"
modules (a `main` importing N−1 independent leaves) and times a **local** edit —
one leaf, cone = 2 — under native vs buildGoApplication, per size:

| N | native edit (cone 2) | buildGoApplication edit (whole) | native wins |
|---|---|---|---|
| 5 | ~942 ms | ~4351 ms | ✓ |
| 10 | ~858 ms | ~4549 ms | ✓ |
| 25 | ~1043 ms | ~4763 ms | ✓ |
| 50 | ~1078 ms | ~4913 ms | ✓ |
| 100 | ~1022 ms | ~5477 ms | ✓ |

native is **flat** (~900 ms — it rebuilds the 2-package cone regardless of N);
bga **grows with N and never goes below ~4 s**, because **a nix buildGoApplication
has no incremental rebuild — every edit re-runs the whole derivation
(`go build ./...`)**. So for a *local* edit native wins at **every** size (the
sweep's `crossover_n` is the smallest probed, 5).

This reframes the earlier "bga beats native at small scale" result: that was the
**foundational** edit (tommy edit-bottom, cone ≈ whole), where native's
per-derivation overhead ×cone exceeds bga's one-shot whole rebuild. The real
determinant is **cone size vs module size**:

- **local edit (small cone)** — the common case — native wins at any size; bga has
  zero incremental, native rebuilds only the cone.
- **foundational edit (cone ≈ whole)** — rare — bga's single derivation wins; native
  pays N × per-derivation overhead.

### Implication for build-system selection

A pure size threshold is the wrong knob — locality is. A practical default:
**native for the incremental dev/test loop** (most edits are local → native's
cone-rebuild beats bga's mandatory whole-rebuild) and **buildGoApplication for
cold / CI / release builds** (everything rebuilds anyway → bga's single-derivation
`go build` has less overhead than N per-package derivations, and parallelism is
in-process). Expose both with a config override; the heuristic is a default, not a
guarantee — a foundational edit in the dev loop is the case where native loses, and
a cold build is where bga is simply the right tool.

## The `godyn gen` contract

`graph.json` is committed (like `gomod2nix.toml`) and regenerated with `just gen`
**only when the import structure or file set changes** — a content-only edit does
*not* need a regen (the measured edit loop never regenerates). This is the
generate→commit→evaluate split that lets nix evaluate the graph purely, with no
import-from-derivation and no build-time resolver.

## Layout / usage

- `module/` — the 4-package toy (`internal/{leaf,mid,top}`, `main.go`).
- `tommy-lib/` — the 7-package real-module snapshot (tommy's pure-Go library).
- `gen/main.go` — the dev-time graph generator (`go list -deps -json` → `graph.json`),
  emitting per-package `local` (vs third-party) so `native.nix` can source local
  packages from the in-repo module and third-party from a gomod2nix vendorEnv.
- `native.nix` — approach A: a graph → per-package CA derivations (reuses
  `../godyn-poc/stdlib.nix`); compile-only manifest when there's no `main`.
- `flake.nix` — `.#{native,recursive,bga}` (toy) and `.#tommy-{native,recursive,bga}`;
  igloo input via `git+file:` (the #25 fix).
- `bench.sh` / `just bench <toy|tommy> [runs]` (JSON) · `just bench-md` (table) ·
  `just gen` · `just build`.

## Deferred (out of scope for the tracer bullet)

Third-party FODs, cgo, Plan 9 asm, the flake-input bridge — all proven in the v1
dewey POC, port into `native.nix` later. Enabling Determinate Nix **lazy-trees**
(#27, kills the per-eval source read; daemon-side, needs host config) and the
FOD-scope fix (#24). The native graph already removes the resolver re-run that
was the residual cost after #25; lazy-trees + this together are the
realistic-deployment story.
