# Warm golangci-lint cache for the hermetic lint lane

Exploration + POC for **spinclass#294** on top of **FDR 0006**
(`buildGoCheck` / `buildGoLint`). Reproduce with:

```
just explore-lint-warm-cache            # spinclass checkout defaults to ~/eng/repos/spinclass
```

## Why #294 happens (read from golangci-lint 2.12.2 source)

- `internal/cache/cache.go:176-181` — for packages of the main module
  (`Module.Version == ""`) the cache key rewrites each file path to
  `module-path + path-within-module`, then hashes content. The key is
  **checkout-path independent**: a `.merge-*` build worktree with identical
  content hits the same entry as the session worktree.
- `pkg/goanalysis/runners_cache.go` — cached issues store the **absolute**
  `Pos` of whichever tree wrote them and replay it verbatim. When that tree is
  deleted, path-based processors (nolint, generated-file filter) cannot open the
  file and fail open → phantom findings against `../.merge-*/…`.

`buildGoLint` already removes the shared writable cache (each build's
`GOLANGCI_LINT_CACHE` is `$TMPDIR` scratch), so it fixes #294 by construction.
Its cost: every run is cold. That is the question explored here.

## Mechanisms considered

| mechanism | verdict |
|---|---|
| Host cache passthrough (`extra-sandbox-paths`, `__noChroot`, darwin-only `__impureHostDeps`) | Rejected. Needs daemon/trusted-user config; reintroduces shared mutable state that outlives its writer (the #294 class); not reproducible. |
| Chain the previous lint output in as the next build's cache | Rejected. The previous output is unknown at eval time without pinning store paths (`builtins.storePath` ⇒ `--impure`) or experimental recursive-nix / CA derivations. |
| Whole-derivation memoization | Already free: unchanged source ⇒ same drv ⇒ store hit, golangci-lint never runs. Coarse — any first-party edit re-runs fully cold. |
| **Deps-keyed warm-up derivation** (`mkGoCacheEnv`'s pattern, extended to golangci-lint) | **Chosen.** Pure, store-cached, re-keyed only by dependency changes. |

## Chosen approach

- `mkGoLintCacheEnv { base, golangci-lint, config ? null, depFiles ? base.src }`
  — `base.overrideAttrs` with `src` filtered to the module-root `go.mod`,
  `go.sum`, `gomod2nix.toml`, `.golangci.*` (keeping the base's unpack
  directory name), and `pwd`/`ldflags`/`version`/`postPatch` neutralized so
  nothing first-party or per-commit reaches the drv. In the base's bridged,
  vendored sandbox it lints a synthetic package that blank-imports every
  importable vendored package, then snapshots `GOCACHE` (dep export data) and
  `GOLANGCI_LINT_CACHE` (dep analyzer facts) as `zstd` tarballs.
- `buildGoCheck { cacheSeed ? null; }` restores both into the per-build scratch
  dirs before `command`. `buildGoLint { warmCache ? false; }` wires it (opt-in
  while experimental); the snapshot is always exposed as
  `passthru.lintCacheEnv`.
- Re-keyed by: go.mod / go.sum / gomod2nix.toml, bridged producers, `go`,
  `golangci-lint`, lint config. **Not** by first-party edits.
- #294-safe: the seed is an immutable store artifact copied into scratch, and it
  holds **no first-party issue entries** (the warm-up never lints first-party
  packages; the synthetic package does not exist in real lint builds).

**`--impure`: not needed.** The helper is pure and works under
`nix flake check`. Only the POC fixture evaluates impurely (it `getFlake`s the
sibling spinclass checkout for its bridged producers).

## Results

spinclass HEAD (4 `goFlakeInputs` bridges, 545 importable vendored packages),
x86_64-linux, one run each on one host — indicative, not a benchmark. Each lane
lints a fresh first-party salt so no lint build is a store hit.

| lane | lint phase | golangci-lint loader | `Execution took` | nix-build wall |
|---|---|---|---|---|
| cold, salt a | 14.8 s | 10.9 s | 14.5 s | 18.9 s |
| warm, salt a | 4.8 s | 2.4 s | 3.5 s | 9.0 s |
| warm, salt b (different source) | 4.7 s | 2.4 s | 3.5 s | 9.1 s |

- `lintCacheEnv` drvPath was **identical** for both salted trees
  (`…-spinclass-lint-cache-deps.drv`); salt b reused the same store path with
  no rebuild.
- The warm-up is a one-time ~36 s per dependency set; its output is 106 MB NAR
  with zero references.
- `GOLANGCI_LINT_CACHE` after the run: 3,723 files cold vs 9,959 warm — the
  seeded dependency facts.

## Limits

- **Path-keyed dependency facts.** golangci-lint keys *dependency* packages by
  absolute file path, so the warm-up must unpack to the same `/build/<name>` as
  the lint build. That holds on the Linux sandbox (`NIX_BUILD_TOP=/build`). On
  Darwin `NIX_BUILD_TOP` is per-build, so I expect the fact half to miss there
  (the `-trimpath` GOCACHE half probably still hits) — **untested theory**.
- **Consumer shapes not handled:** `sourceRoot`/`modRoot` overrides,
  workspace-mode bridges (`go.work`), and extra consumer attrs that interpolate
  first-party source would break or re-key the warm-up.
- **`pwd` must be a path** (e.g. a flake's `src = ./.`). A store-path *string*
  makes the merged go.mod depend on the whole source, so the seed re-keys every
  commit — still correct, just never warm.
- First-party packages are always analyzed cold by design; that is the
  remaining ~3.5 s.
- Storage: ~100 MB per dependency set per system; each dep bump builds a new
  seed. Ordinary GC applies.
- The synthetic package draws real findings (e.g. SA1019 on
  `golang.org/x/crypto/openpgp/errors`); the warm-up runs with
  `--issues-exit-code=0` so only runner failures fail it.
- Generic `buildGoCheck` tools only benefit from the GOCACHE half unless they
  read `GOLANGCI_LINT_CACHE`.

## Suggested consumer wiring (spinclass's lane — not changed here)

```nix
checks.lint = pkgs.buildGoLint {
  base = self.packages.${system}.default;
  golangci-lint = pkgs-master.golangci-lint;
  warmCache = true;
};
```

…and drop golangci-lint from the impure `lint-worktree` lane.
