# godyn → godyn composition POC

Can a godyn-built module consume *another* godyn-built module, and what's the
difference between consuming it **via compiled outputs** vs **via source + go.mod**?

Fixture: module **A** `example.com/dep` (package `greet`) and module **B**
`example.com/app` (a `main` that calls `greet.Hello()`), wired with a `go.mod`
`require` + `replace` so `go build`/`go list` resolve A locally.

## The two approaches

- **Approach 1 — output bridge** (`appBridge`): A's `greet` is built as a compiled
  **archive output** (conceptually from A's own flake); B's `app` **links** it.
  `greet` is *not* a node in B's compile graph. B needs only A's archive (+ a
  matching toolchain).
- **Approach 2 — source via flake-input/go.mod** (`appSource`): A's `greet` is a
  **node in B's graph**, compiled from A's **source** (arriving via a flake input,
  resolved through `go.mod`). B recompiles `greet`.

The orthogonal axis the disambiguation surfaced: *both* deliver A as a flake input;
the difference is whether B consumes A's **archive** (approach 1) or A's **source**
(approach 2).

## Finding: under godyn, the two approaches CONVERGE at the build level

godyn names every per-package archive by its **import path**
(`godyn-compile-<importpath>`) and the archive is **content-addressed**, with
`go tool compile -trimpath` canonicalising the source path out of the output.
Measured:

- `greet` compiled from **two different source store paths** (A's-flake route vs
  B's-flake-input route) produces the **exact same** store path
  `…-godyn-compile-example-com-dep-greet` — CA dedups across routes. So the source
  path does **not** leak into the archive.
- Both apps run (`hello from dep/greet`), and their `app` binaries are
  **byte-identical**.

So "consume A via outputs" and "consume A via source + go.mod" realise to the **same
compiled archive and the same binary** — there is **no duplicated compilation**. The
choice is *not* a build-efficiency tradeoff.

## What actually differs (so the choice is real)

| | Approach 1 (outputs) | Approach 2 (source + go.mod) |
|---|---|---|
| B's graph contains A's pkgs | no (linked archive) | yes (compiled nodes) |
| B needs from A | the **archive** | the **source** + a `go.mod` edge |
| Toolchain coupling | A's archive must match B's go/stdlib | always B's toolchain → consistent |
| A built/versioned | independently, in A's flake | inside B's build |
| Incremental edit to A | A's archive rebuilds (A's flake) → B relinks | A's node rebuilds in B's graph → B relinks |

Both give the cross-module merkle-delta (edit A → only the changed archive rebuilds,
B relinks).

## Recommendation

Since the two **converge at the build level**, the decision is purely workflow /
maintenance ergonomics. **Default to approach 2 (source via flake-input + go.mod).**

Discriminating factors, ranked:

1. **Toolchain coupling (dominant).** Go archives are go-version-specific (the
   compiler/linker reject mixed-toolchain builds). Approach 1 makes *every*
   producer↔consumer edge require the identical go toolchain, so a go bump must land
   in lockstep across A's archive-flake and all consumers (exactly the conformist
   1.26.2→1.26.3 coordination we did — but standing, on every edge). Approach 2 has no
   such invariant: B's toolchain compiles A, so bumps "just work". *(Reasoned from
   Go's version-skew rule; the POC used one toolchain on both sides, so not measured
   here — verify by linking a differently-built archive if certainty is needed.)*
2. **Version source-of-truth.** Approach 1 declares A twice (B's go.mod + B's flake
   input) — they can drift, so `go build` and the nix build compile different A's.
   Approach 2 routes A's source through go.mod, keeping one truth.
3. **Graph modularity / re-gen churn.** Approach 1 keeps A out of B's graph (B
   re-gens only when B's own imports change). Approach 2 inlines A's transitive graph
   into every consumer, so a *structural* change in A drifts all consumers' graphs.
4. **Alignment.** godyn's existing dep handling (vendorEnv, `bridges`) is already
   source-based — approach 2 is that model extended; approach 1 is new machinery.

**Reserve approach 1 (output bridge)** for when its benefits are decisive: A is an
independently-versioned / published / **sealed** unit with many consumers; A is
**closed-source / pre-built**; or A is large and you want to isolate consumers from
its graph size/churn.

**Not a one-way door:** because both realize the same CA archives, you can ship
approach 2 now (smaller lift, lower maintenance) and add approach 1 (`archiveBridges`)
later with zero change to build outputs.

## Build it

```
nix build .#appBridge   # approach 1
nix build .#appSource   # approach 2
nix build .#greetArchive .#greetAlt   # the two source routes (same store path)
```

POC scope: focused `cross-native.nix` (reuses the godyn stdlib + compile/link
conventions), not the productionized builder. A real implementation would add an
`archiveBridges` arg to the builder (approach 1) and the flake-input/go.mod
resolution at gen time (approach 2) — but per the finding above they converge, so a
single mechanism (per-package CA archives keyed by import path) covers both.
