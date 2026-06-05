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

## Results — edit loop (4-package module)

`just measure` (wall-clock ms; "pkgs" = packages nix actually recompiled, visible
only for the native graph; edits use a unique token to force a real rebuild):

| scenario | A: native (eval graph) | B: recursive (resolver) | buildGoApplication |
|---|---|---|---|
| warm (no change) | **385 ms** | 894 ms | 411 ms |
| edit leaf (cone = 4) | **1346 ms** · 4 pkgs | 2773 ms · 4 pkgs | 4358 ms |
| edit top (cone = 2) | **1292 ms** · 2 pkgs | 2164 ms · 2 pkgs | 4348 ms |
| comment in leaf | **1147 ms** · 2 pkgs | 1785 ms · 1 pkg | 4469 ms |

### What this shows

1. **The #26 payoff is real: native ≈ 2× faster than the recursive resolver on
   every edit**, rebuilding the *same* cone. The delta is exactly the resolver
   re-run the native graph eliminates — nix's own scheduler does the merkle-delta
   from the `inputDrvs` it already has, with nothing to re-discover.
2. **Both beat `buildGoApplication` ~3×**, whose edit cost is a flat ~4.3 s
   whole-module rebuild regardless of what changed (no per-package granularity).
3. **Native's cost scales with the dependency cone** (edit-leaf 4 pkgs > edit-top
   2 pkgs), and the **CA early-cutoff** keeps a comment from cascading the whole
   way (top/main stay cached; the one-level leaf→mid propagation is Go folding the
   edit into export data, not a nix limitation).
4. **Warm (no-change) is a digest match → 0 recompiles**; native (385 ms) ties
   `buildGoApplication` (411 ms) and beats the recursive wrapper's eval overhead
   (894 ms).

On this tiny module the absolute deltas are ~1 s; the point is the **slope** — B's
resolver re-run grows with package count (re-`go list` + N×`derivation add` +
N×`nix build` cache-check), while A's overhead is nix eval + the cone's compiles
(parallelised). At dewey scale (74–273 packages) the gap widens accordingly.

## The `godyn gen` contract

`graph.json` is committed (like `gomod2nix.toml`) and regenerated with `just gen`
**only when the import structure or file set changes** — a content-only edit does
*not* need a regen (the measured edit loop never regenerates). This is the
generate→commit→evaluate split that lets nix evaluate the graph purely, with no
import-from-derivation and no build-time resolver.

## Layout / usage

- `module/` — the system under test (`go.mod`, `internal/{leaf,mid,top}`, `main.go`).
- `gen/main.go` — the dev-time graph generator (`go list -deps -json` → `graph.json`).
- `native.nix` — approach A: `graph.json` → per-package CA derivations (reuses
  `../godyn-poc/stdlib.nix`).
- `flake.nix` — `.#native` (A), `.#recursive` (B), `.#bga` (baseline); igloo input
  via `git+file:` (the #25 fix).
- `just gen` · `just build` (all three print `godyntb value = 15`) · `just measure`.

## Deferred (out of scope for the tracer bullet)

Third-party FODs, cgo, Plan 9 asm, the flake-input bridge — all proven in the v1
dewey POC, port into `native.nix` later. Enabling Determinate Nix **lazy-trees**
(#27, kills the per-eval source read; daemon-side, needs host config) and the
FOD-scope fix (#24). The native graph already removes the resolver re-run that
was the residual cost after #25; lazy-trees + this together are the
realistic-deployment story.
