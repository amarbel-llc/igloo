# gocheck-poc — hermetic `buildGoLint` resolves a bridged-only package

POC for **FDR 0006** (`docs/features/0006-hermetic-go-check-lanes.md`) and
**amarbel-llc/igloo#62**.

## Hypothesis

`buildGoLint` (over a `goFlakeInputs`-bridged `buildGoApplication` base) runs
golangci-lint **inside the build sandbox**, where the merged `go.mod` +
vendored bridge are already materialized — so it resolves a package that
exists **only** in a bridged producer's source (absent at the consumer's
required version), hermetically and offline. This is the pure answer to
"ambient devshell tooling can't see the bridge": the tool runs where Nix owns
the working tree, so no `go.mod`/`go.work` materialization against a live
checkout is needed.

## Fixture

- `producer/` — module `example.com/producer` with `newpkg` (`Value()`).
- `consumer/` — imports `example.com/producer/newpkg`; its `go.mod` **requires
  `example.com/producer v1.0.0`**, a fictional version that has no `newpkg` and
  is unreachable via any proxy. It bridges the module via `goFlakeInputs` to the
  local `./producer` source. So `producer/newpkg` resolves **only** through the
  bridge — the mesa-in-newer-dewey shape.
- `consumer/.golangci.yml` — enables a single benign linter (`govet`). The POC
  proves *resolution* (package loading), not lint strictness; a resolution
  failure surfaces as a load/`typecheck` error regardless of linters.

## Run

```
just -f zz-pocs/gocheck-poc/justfile nix-build          # phase 2: PASS (green)
just -f zz-pocs/gocheck-poc/justfile nix-build-control  # phase 3: control fails
# or directly:
nix-build zz-pocs/gocheck-poc -A lint --no-out-link     # green
nix-build zz-pocs/gocheck-poc -A control --no-out-link  # fails to load newpkg
```

`nix-build` rejects untracked paths under a git worktree — `git add -N
zz-pocs/gocheck-poc` first if the fixture is not yet staged.

## Verified result

- **Phase 2 (`-A lint`, bridged):** green — `golangci-lint … 0 issues`,
  resolving `producer/newpkg` from the vendored bridge with `GOPROXY=off`.
- **Phase 3 (`-A control`, unbridged):** build fails with
  `could not import example.com/producer/newpkg (cannot find module providing
  package …: import lookup disabled by -mod=vendor) (typecheck)`.

The two derivations differ **only** in whether `goFlakeInputs` bridges the
producer, so the bridge is exactly what makes golangci-lint resolve the
package inside the sandbox.

## Warm cache (spinclass#294)

`warm-cache.nix` + `just explore-lint-warm-cache` measure the opt-in
deps-only lint cache (`mkGoLintCacheEnv`, `buildGoLint { warmCache = true; }`)
against real spinclass. Writeup: `WARM-CACHE.md`.
