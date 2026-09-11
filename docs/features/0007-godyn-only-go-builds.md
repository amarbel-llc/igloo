---
status: exploring
date: 2026-09-11
promotion-criteria: |
  exploring → proposed: godyn is the DEFAULT build of at least one fleet
  consumer with a full package (not a bare binary) — spinclass, on
  x86_64-linux — using the postInstall install step, with
  buildGoApplication demoted to a named escape hatch; and the known gaps
  below each have a tracking issue.

  proposed → experimental: that consumer's flake checks are godyn-native
  end to end — per-package tests (passthru.checkAll), vet (vetAll) and
  lint (buildGodynLint) — and its whole-module buildGoApplication
  test/lint lanes are retired. godyn builds and runs on darwin and
  aarch64 from per-system graphs (igloo#33), so the consumer drops its
  per-system backend gate.

  experimental → testing: every fleet Go repo builds its packages and
  runs its checks through godyn + flake-input-go_mod (RFC 0001), no
  consumer declares a buildGoApplication/buildGoModule package output, and
  no consumer commits a package graph — each is derived at eval time
  from the module's nix manifest (FDR 0008).

  testing → accepted: the fleet has carried the godyn-only arrangement
  for a release cycle with no consumer re-adding a second Go build path,
  and the buildGoApplication escape hatches are removed.
---

# godyn + flake-input-go_mod as the only way to build Go

## Problem Statement

The fleet builds Go several different ways at once:

- **buildGoApplication** (gomod2nix) — most repos' package output (madder,
  dodder and others), their `go test ./...` checkPhase, and the whole-module
  lint lanes `buildGoCheck` / `buildGoLint` (FDR 0006).
- **buildGoModule** (`vendorHash`) — a few in-tree tools (e.g. igloo's own
  `godyn-gen`).
- **godyn** (`buildGodynModule`, `buildGoAuto`) — per-package, content-
  addressed builds. Opt-in in conformist; opt-in in spinclass
  (`.#spinclass-native`), with the operator's decision to flip spinclass's
  default to godyn pending.
- **Ambient `go`** in devshells and justfiles, for the inner dev loop.

Every path re-solves the same problems separately — cross-flake module
composition, version embedding, the install step, tests, vet, lint, caching —
and each solution only helps the consumers on that path. The whole-module
paths have no incremental build at all: a one-package edit re-runs the whole
`go build` (and the whole lint). The warm-cache work on spinclass#294 shows how
far a whole-module lint can be pushed (seeded cache, 14.8 s → 4.8 s lint phase)
and where it stops: first-party packages are always analyzed cold, and the
seed is a 106 MB per-dependency-set store artifact.

godyn has the shape that removes most of this. One derivation per package,
wired by nix string context, gives nix the whole package DAG at eval time; an
edit rebuilds only the edited package's dependency cone. On spinclass, after
an edit to one package, the spinclass migration session measured about 3.7 s for
the godyn build against about 34 s for buildGoApplication. The same per-package
structure carries tests, vet and lint, because each package's export data and
analysis facts are exactly what those need.

## Vision

**The only way to build Go across the fleet is godyn, with cross-repo
dependencies composed by the flake-input-go_mod protocol (RFC 0001).**

- **Packages** are `buildGodynModule` (or `buildGoAuto` while a consumer
  migrates) over a `godyn-gen` package graph — committed today; under FDR 0008
  derived at eval time from the module's nix manifest, with nothing committed.
- **Fleet dependencies** are `goFlakeInputs` (RFC 0001): the flake input's rev
  in `flake.lock` is the single source of truth, never a `go.mod`
  pseudo-version plus a `gomod2nix.toml` hash in lockstep. godyn resolves
  `goFlakeInputs` exactly as buildGoApplication does (igloo#69); graphs are
  generated against the merged go.mod with `godyn-gen -gomod` (igloo#67).
- **Third-party dependencies** come from the consumer's `gomod2nix.toml`
  vendor tree.
- **Checks** are godyn-native: per-package `go test` (`passthru.checkAll`),
  vet (`passthru.vetAll`), and lint (`pkgs.buildGodynLint` — vet's passes plus
  staticcheck's defaults, honoring golangci-lint `//nolint`). Each is one
  content-addressed derivation per package, re-run only for the edited cone.
- **Install steps** (generated manpages and completions, plugin manifests,
  symlinks) are godyn's `postInstall` / `nativeBuildInputs`.

**What stays.** buildGoApplication remains as igloo-internal machinery — godyn
derives its vendor tree (`passthru.vendorEnv`) and the RFC 0001 merged go.mod
(`passthru.mergedGoMod`) through it — but not as a consumer-facing package
output. Ambient `go` / `gopls` in the devshell remain the editor loop; the
authoritative build, test and lint are godyn's (the reason the devshell cannot
be authoritative is recorded in FDR 0006 § *Why not fix the devshell?*).

## Current State (2026-09-11)

| Capability | godyn today | Gap |
|---|---|---|
| Build, cross-flake bridges, embeds, ldflags/version | done (igloo#67/#68/#69) | — |
| Install step | `postInstall` / `nativeBuildInputs`, forwarded by buildGoAuto to both backends | — |
| Per-package `go test` | `testGraphFile` → `tests` / `checkAll` | cgo/asm tests, test-only third-party deps, `-race`, test-only embeds (igloo#32); no `nativeCheckInputs`-style tools on the test PATH (unverified) |
| Per-package vet | `vetAll` (toolchain vet, or `vetTool`) | cgo packages and test sources not analyzed |
| Per-package lint | `buildGodynLint` (godyn-lint: vet + staticcheck defaults, `//nolint`) | `.golangci.yml` not read; x/tools pinned below the type-bearing vetx protocol (igloo#71) |
| Platforms | default on every supported system (`godynSystems`); x86_64-linux proven (two fleet hosts) | darwin / aarch64 builds unvalidated on real builders (igloo#33) |
| Package graph | committed graph, or derived at eval time from go.mod + gomod2nix.toml when no `graphFile` is given (build and test graphs; igloo#72) | derivation from the nix manifest instead of go.mod (FDR 0008); consumers still committing graphs migrate |
| Workspace consumers | `-gomod` takes a merged go.mod | go.work consumers (igloo#73) |
| Nix features | content-addressed derivations | `ca-derivations` on every building host — eng-managed hosts declare it today; circus will own it fleet-wide |
| buildGoAuto's bga backend | builds | eval fails without `version` / `version.env` (igloo#70) |

## Rollout

1. **Opt-in** — a consumer adds a godyn package next to its existing build
   (conformist, spinclass today).
2. **Default on x86_64-linux** — godyn becomes `packages.default` there;
   buildGoApplication stays default elsewhere and as a named escape hatch
   (spinclass's planned `.#spinclass-build_go_application`).
3. **Godyn checks** — the consumer's tests, vet and lint move to godyn's lanes;
   the whole-module lanes are retired.
4. **Default everywhere** — configured: `godynSystems` lists every supported
   system, so godyn is `packages.default` on all of them and consumers carry no
   per-system backend gate (derived graphs are per-system by construction).
   Building and gating on darwin / aarch64 awaits real builders (igloo#33).
5. **Single path** — the escape hatch is removed; the consumer declares no
   other Go build.

igloo's own Go tools follow the same path once godyn can build a tool with
third-party dependencies inside igloo itself (today godyn-lint and the gomod2nix
CLI use buildGoApplication, godyn-gen buildGoModule).

## Limitations and Open Questions

- **Committed graphs (interim).** A graph describes one platform and one
  dependency set; a stale graph builds the wrong file set. The end state is no
  committed graph — derived at eval time from the manifest (FDR 0008), which
  accepts that evaluating another system's packages needs a builder for that
  system, as goFlakeInputs consumers already do. Until then, a drift check
  (igloo#72) keeps committed graphs honest.
- **Cold builds.** Per-package derivations cost more than one `go build` from
  cold (spinclass: about 205 derivations). The trade — slower cold,
  much faster incremental, shared per-package cache hits across consumers — is
  accepted; the fleet's binary cache is what keeps cold consumers fast.
- **`ca-derivations` is required** on every host that builds godyn outputs.
  A host or CI runner without it fails at evaluation.
- **golangci-lint parity.** The godyn lint runs analyzers, not golangci-lint:
  linters outside the go/analysis framework, formatters, and golangci-lint
  configuration do not carry over. Whether that gap is acceptable, or needs a
  broader analyzer suite, is open.
- **Protocol churn.** Newer `go vet` tooling moves type data into the vetx
  files (igloo#71); the vet and lint lanes must follow before the toolchain
  moves to it.

## More Information

- godyn(7) — the builder, `buildGoAuto`, TESTS, VET, LINT.
- RFC 0001 (`docs/rfcs/0001-flake-input-go_mod.md`) — the dependency protocol.
- FDR 0006 (`docs/features/0006-hermetic-go-check-lanes.md`) — the
  whole-module check lanes this supersedes once consumers are godyn-native.
- FDR 0003 / FDR 0004 — the bridge's journey (superseded by RFC 0001).
- FDR 0008 (`docs/features/0008-nix-authoritative-go-modules.md`) — a nix
  manifest replacing go.mod as the source of truth, with a bidirectional
  go.mod ↔ manifest escape hatch for editors.
- Issues: igloo#32 (tests), igloo#33 (platforms), igloo#70 (bga eval),
  igloo#71 (vetx protocol), igloo#72 (graph drift check), igloo#73 (go.work
  consumers).
