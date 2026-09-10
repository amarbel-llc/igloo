---
status: experimental
date: 2026-08-26
promotion-criteria: |
  proposed → experimental: [MET 2026-08-26] `buildGoCheck` + `buildGoLint`
  landed in `pkgs/build-support/gomod2nix/default.nix`, and the POC in
  `zz-pocs/gocheck-poc/` runs golangci-lint hermetically against a
  `goFlakeInputs`-bridged consumer and resolves a bridged-only package
  offline — `nix-build -A lint` green ("0 issues"), `-A control`
  (unbridged) fails with `cannot find module providing package …/newpkg`.

  experimental → testing: at least one fleet consumer (spinclass)
  exposes its golangci-lint run as a `buildGoLint` flake check that
  resolves its bridged modules — including a package that exists ONLY
  in a bridged producer's newer rev (the mesa-in-dewey case) — and
  retires the impure `lint-worktree` golangci-lint invocation.

  testing → accepted: the hermetic lint lane has carried spinclass
  (and one more consumer) for a release cycle with no consumer needing
  to hand-roll a go.mod/go.work materialization for ambient tooling.
---

# Hermetic Go check/lint lanes (buildGoCheck / buildGoLint)

## Problem Statement

Package-loading Go tools — golangci-lint, staticcheck, custom `go vet`
analyzers, anything driven by `go/packages` — must resolve the full
import graph to do their job. When a consumer bridges a sibling Go
module via `goFlakeInputs` (FDR 0003, RFC 0001), that graph includes a
`replace <module> => /nix/store/...` that exists **only inside a `nix
build` sandbox**; it never reaches an ambient tool run against the
working tree (amarbel-llc/igloo#62). The tool then resolves the bridged
module at its stale, proxy-fetchable `require` version — which is
invisible when it happens to still contain the imported packages, and a
hard failure when the bridge's whole point is a *newer* producer rev
that adds a package the required version lacks (e.g. a consumer
importing `.../dewey/pkgs/mesa` while `go.mod` requires `dewey v0.5.0`,
which predates `mesa`). The tool reports `no required module provides
package …/mesa` — a false lint failure with no bridged-module bug
behind it.

There is no pure way to deliver the bridge to an ambient checkout (see
*Why not fix the devshell?*), so the resolution is to stop running these
tools ambiently: run them **inside the same hermetic sandbox where the
bridge is already materialized**, exactly as the existing `go test
./...` checkPhase already resolves bridged modules.

## Interface

Two helpers on `pkgs`, alongside `buildGoRace` / `buildGoCover`, both
built by `overrideAttrs` on a `buildGoApplication`-produced base (so
they inherit its `src`, the merged-`go.mod` `postPatch`, and
`goConfigHook`'s vendored bridge + `-mod=vendor` / `GO_NO_VENDOR_CHECKS=1`
/ `GOPROXY=off` / `go`-on-PATH environment):

- **`buildGoCheck { base, command, extraNativeBuildInputs ? [],
  pnameSuffix ? "-check", cacheSeed ? null, passthru ? {} }`** — the
  general primitive. Runs `command`
  (a shell fragment) in the bridged sandbox with a writable `HOME` and
  Go caches, after the vendor tree and env are set up. It is
  **lint-only**: it replaces the base's build phase, so no binary is
  compiled or installed — producing the binary stays a separate
  derivation's job (`packages.default`, the base itself). The
  derivation's output is an empty marker (`touch $out`) on success; a
  non-zero `command` fails the build. `extraNativeBuildInputs` puts the
  tool the command needs (golangci-lint, staticcheck, …) on PATH.

- **`buildGoLint { base, golangci-lint, config ? null }`** — a thin
  wrapper over `buildGoCheck` that runs `golangci-lint run` (with
  `-c ${config}` when a config is passed; otherwise golangci-lint's
  own walk-up finds the repo's `.golangci.yml` in `src`). The
  golangci-lint package is a required argument so the consumer pins the
  version (typically `pkgs-master.golangci-lint`). Also takes
  `extraArgs ? []` and `warmCache ? false` (below).

- **`mkGoLintCacheEnv { base, golangci-lint, config ? null }`** —
  *experimental warm cache* (spinclass#294). A
  deps-only derivation: the base's bridged sandbox over a `src` filtered
  to the module-root `go.mod`/`go.sum`/`gomod2nix.toml`/`.golangci.*`,
  linting a synthetic package that blank-imports every vendored package,
  snapshotting `GOCACHE` + `GOLANGCI_LINT_CACHE`. First-party edits do
  not re-key it. `buildGoLint { warmCache = true; }` passes it to
  `buildGoCheck`'s `cacheSeed`, which restores it into the per-build
  scratch caches; it is always exposed as `passthru.lintCacheEnv`. It
  holds no first-party issue entries, so it cannot replay findings
  against a vanished tree. Design, measurements, and limits:
  `zz-pocs/gocheck-poc/WARM-CACHE.md`.

Neither helper touches the working tree, sets no env in the devshell,
and produces a normal derivation the consumer wires as a flake `check`
and a `just` target (`nix build .#<pkg>-lint`).

## Examples

A consumer replaces its impure worktree golangci-lint run with a
hermetic check:

```nix
# flake.nix
let
  spinclass = pkgs.buildGoApplication {
    pname = "spinclass";
    src = ./.;
    inherit goFlakeInputs;      # bridges dewey/tommy/crap/ringmaster
    # ...
  };
in {
  packages.spinclass-lint = pkgs.buildGoLint {
    base = spinclass;
    golangci-lint = pkgs-master.golangci-lint;
    # config = ./.golangci.yml;  # optional; auto-found in src otherwise
  };

  checks.spinclass-lint = self.packages.${system}.spinclass-lint;
}
```

```
# was: impure `just lint-worktree` running golangci-lint against $PWD
nix build .#spinclass-lint          # hermetic; resolves the bridge
```

A different package-loading tool via the general primitive:

```nix
packages.spinclass-staticcheck = pkgs.buildGoCheck {
  base = spinclass;
  extraNativeBuildInputs = [ pkgs-master.go-tools ];  # staticcheck
  command = "staticcheck ./...";
  pnameSuffix = "-staticcheck";
};
```

## Why not fix the devshell?

The natural instinct is to make the `mkGoEnv` devshell's ambient `go`
resolve the bridge (the original "mkGoEnv parity" promise). This is not
achievable purely, and the reason is worth recording so it is not
re-litigated:

Go anchors module resolution on the **runtime working-directory path**.
To apply a `replace` to a consumer's code, the directive must live in a
`go.mod`/`go.work` that is either physically in the live checkout or
names the checkout's absolute path (a `go.work` `use <path>`). "Where
the repo is checked out" is not a nix-eval-time value — the same
devShell closure serves every checkout location — so a store-only
artifact cannot carry it. Every ambient mechanism therefore reduces to
either mutating a tracked file or supplying the checkout path at
runtime:

- **`GOFLAGS=-modfile=<store merged.mod>`** — rejected by golangci-lint:
  its `go/packages` loader runs a `go list -f '{{context.ReleaseTags}}'
  -- unsafe` probe under `GO111MODULE=off`, and cmd/go rejects
  `-modfile` under `GO111MODULE=off` (`build flag -modfile only valid
  when using modules`). An outer `GO111MODULE=on` does not help — the
  probe overrides it.
- **Materialize the merged `go.mod` into the tree** — resolves for all
  tools, but mutates a version-controlled file (accidental-commit risk)
  and fights `go-sync-wrap`.
- **A `go.work` overlay (`use <checkout>` + replaces)** — resolves for
  all tools including golangci-lint (verified: it loads a replace-only
  package offline, and does not trip the `-modfile` probe), but the
  `use` line needs the runtime checkout path, so it must be generated at
  shell entry and either written into the tree or exported via `GOWORK`
  to an out-of-tree file — an impure, runtime step, not a pure
  environment property.

`nix build` sidesteps all of this because inside the sandbox the
"working tree" is a source copy **Nix itself places** — so writing the
merged `go.mod` into it is pure and invisible. The hermetic check lane
reuses exactly that property. The devshell remains a place for the
inner dev loop (where the proxy-reachable version usually suffices);
authoritative, bridge-aware checking is the sandbox's job.

## Limitations

- **Not a devshell/editor fix.** `gopls` and an ambient `go build` in
  `nix develop` still resolve bridged modules only via GOPROXY at the
  organic `require` version (they work when that version carries the
  imported packages, and cannot see a bridged-only package). This lane
  is a CI/gate mechanism, not an inner-loop one. See *Why not fix the
  devshell?* and `gomod2nix(7) § mkGoEnv devshell scope`.
- **Coarse-grained.** The sandbox compiles from the vendored graph on
  each run; it is a gate, not an incremental red/green loop. Consumers
  keep a fast ambient `go test`/`golangci-lint` for iteration where the
  bridge is not load-bearing.
- **golangci-lint version is the consumer's to pin** (the
  `golangci-lint` argument). The lane does not bundle a version.
- **Depends on the base's vendored bridge.** `buildGoCheck` assumes the
  base is a `buildGoApplication` derivation whose `postPatch` +
  `goConfigHook` set up the merged `go.mod` and vendor tree. It is not
  meant to wrap arbitrary derivations.

## Tuning Levers

| Lever | Current | Rationale | Change signal |
|---|---|---|---|
| default `pnameSuffix` | `-check` / `-lint` | matches `buildGoRace`'s `-race` / `buildGoCover`'s `-cli-cover` naming | a consumer needs multiple check lanes and the suffixes collide |
| golangci-lint cache location | `$TMPDIR` (per-build), cold unless `warmCache = true` seeds it from the deps-only `mkGoLintCacheEnv` | hermetic + no shared writable state; the opt-in seed is an immutable store artifact (spinclass: 14.8 s → 4.8 s lint phase, 106 MB seed) | the seed's dependency facts miss on Darwin (per-build `NIX_BUILD_TOP`, untested) or its storage cost outweighs the lint time saved |

## More Information

- Tracking issue: amarbel-llc/igloo#62 (mkGoEnv bridge never reaches
  the ambient devshell `go`) — this feature is its resolution by
  reframing the lint as a hermetic lane.
- Bridge FDR / protocol: `docs/features/0003-bridge-go-flake-inputs.md`,
  `docs/rfcs/0001-flake-input-go_mod.md`.
- Sibling `overrideAttrs` wrappers this mirrors: `buildGoRace`,
  `buildGoCover` in `pkgs/build-support/gomod2nix/default.nix`.
- Consumer doc: `gomod2nix(7)` (`§ mkGoEnv devshell scope`,
  `§ golangci-lint and the bridge`) documents the devshell limitation
  this lane resolves; it will be updated to point at the hermetic lane
  as the recommended path once this lands.
- First expected consumer: spinclass (retires its impure
  `lint-worktree` golangci-lint invocation), motivated by the
  `sc list` → `.../dewey/pkgs/mesa` migration.
