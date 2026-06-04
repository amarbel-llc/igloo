# godyn-poc — native per-package Go builder (recursive-nix + CA + dynamic-derivations)

Throwaway POC reimplementing numtide/go2nix's "experimental dynamic mode"
mechanics **natively in igloo** (no numtide flake input). Validates the full
pipeline — stdlib → per-package CA compile → link, with build-time graph
discovery via `nix derivation add` — on a tiny toy module, before any
production builder or real consumer (purse-first / madder / dodder) is touched.

See the prior de-risk research in
`../../docs/features/0001-numtide-go2nix-overlay-builder.md`
§ *De-risk findings (2026-06-03)* and the plan at
`~/.claude/plans/structured-brewing-grove.md`.

## Hypothesis

Per-package CA derivations isolate rebuilds: editing one package's **private**
internals leaves dependents' (and the final binary's) store paths unchanged,
while editing an **exported** signature cascades. The open question (R6) is
whether numtide's single-`.a` dynamic mode delivers this via byte-identical
recompile + CA short-circuit, or whether the iface/export-data split is needed.

## Prerequisite (M0)

The daemon must advertise `recursive-nix` + `dynamic-derivations`, have
`recursive-nix` in `system-features`, and trust the dev user. Enable with
`just enable-recursive-nix` (root, via pkexec), verify with `just preflight`.
Codifying this for new boxes is tracked in amarbel-llc/igloo#27.

## Milestones

- **M0 preflight** — `just preflight`. Gates M2+.
- **M1 stdlib alone** — `just m1`. Build the stdlib derivation, assert
  importcfg references real `.a` files. No recursive-nix.
- **M2 single package** — single `main.go`. wrapper / `outputOf` /
  `nix derivation add` / CA-compile / link in isolation.
- **M3 multi first-party + importcfg** — `main → greet → mathx`.
- **M4 third-party via FOD** — `nix build .#m4`. `greet` imports
  `github.com/google/uuid`, fetched via a fixed-output derivation.
- **M5 cache-isolation proof** — S2 (private-change isolation) + S3
  (exported-change cascade); report the R6 regime.

## Findings

_(filled in as milestones land)_

- **M1: PASS.** `nix build .#stdlib` →
  `go-stdlib-1.26.3-44136fa3` (go 1.26.3, ~24s, plain input-addressed, no
  recursive-nix). `GODEBUG=installgoroot=all go install --trimpath std`
  populates `GOROOT/pkg/linux_amd64/` as expected; importcfg has 353
  `packagefile` entries (full stdlib + vendored `golang.org/x/*`), every
  target archive present on disk (`fmt.a` 1.05 MB, `net.a` 3.88 MB, …).
- **M2: PASS.** `nix build .#m2` → a binary that prints
  `godyn single-package M2 ok`. The full dynamic chain works on this stack:
  text-mode CA wrapper (`requiredSystemFeatures=["recursive-nix"]`) runs the
  resolver, which `nix store add`s the staged source, `nix derivation add`s a
  floating-CA compile drv (v4 JSON: `{"version":4,…,"outputs":{"out":{"method":"nar","hashAlgo":"sha256"}}}`),
  `nix build`s it, then registers the link drv and copies its `.drv` to `$out`;
  `builtins.outputOf wrapper "out"` resolves that to the linked binary.
  Two gotchas resolved: (1) `nix store add` output needs trimming; (2)
  `nix derivation add` does NOT auto-inject `$out` — the compile/link drvs must
  set `env.out` to the self-output placeholder `hashPlaceholder("out")` =
  `/` + nixbase32(sha256("nix-output:out")).
- **M3: PASS.** `nix build .#m3` → binary prints `hello godyn; 2+3=5`
  (`main → internal/greet → internal/mathx`). `go list -deps` yields
  deps-before-dependents, so the resolver compiles `mathx`, then `greet` (with
  `mathx.a` in its importcfg), then `main` (with both), then links. Per-package
  floating-CA compile derivations, each referencing upstream archives by
  concrete CA store path. No code changes from M2 — the resolver was written
  multi-package-capable from the start.
- **M4: PASS — `nix build .#m4`.** `toy-m4`'s `greet` imports a third-party
  module (`github.com/google/uuid`); the binary prints
  `hello godyn; 2+3=5; uuid=2c29e2bb-...` (a correct deterministic v5 uuid),
  proving the full third-party path end to end: a **fixed-output derivation**
  runs `go mod download` and outputs uuid's extracted tree; the resolver
  assembles a **GOMODCACHE** (symlinked tree + synthesised
  `cache/download/<mod>/@v/{.mod,.info,.ziphash,.lock}`, with the ziphash =
  the h1 from the lockfile); `go list` (`GOPROXY=off -mod=mod
  GODEBUG=embedfollowsymlinks=1`) resolves it; uuid compiles as its own
  per-package CA derivation (source straight from the FOD path) and is wired
  into `greet`'s importcfg by concrete CA path. The lockfile is
  `path version nar-sri h1`; the NAR hash drives the FOD, the h1 the ziphash.
  Modinfo (`go version -m`) is intentionally out of scope, so it isn't embedded.
- **M5: PASS (decisive) — `just m5`.** Compared `internal/greet`'s compiled-CA
  store path across edits to `internal/mathx`:
  - **S2 noinline → ISOLATION HOLDS.** With `//go:noinline` on `mathx.Add`/
    `addImpl`, a private-body change yields a **byte-identical** `greet.a`
    (same CA path) → the CA derivation short-circuits. The per-package caching
    mechanism works.
  - **S2 inlinable → greet CHANGED.** Without noinline, Go's **cross-package
    inlining** copies `mathx`'s private body into `greet.a`, so a private
    change leaks across the package boundary and `greet`'s CA path moves.
  - **S3 exported → greet CHANGED** (control): an interface change cascades.

  ### R6 verdict

  Per-package CA isolation is **real but bounded by Go's cross-package
  inlining.** The "a private change doesn't cascade" guarantee holds only at
  **non-inlinable** boundaries. Important: the iface/export-data split
  (numtide's `IfaceOutput`, `.x`) does **not** fix this — Go's export data
  *includes* inlinable function bodies (that is how cross-package inlining
  works), so the inlined body still reaches the consumer's compile input. The
  only way to fully isolate is to disable cross-package inlining
  (`-gcflags=all=-l`), trading runtime performance for cache reuse.

  **Implication for the real builder (dodder):** the cache-hit rate on a
  localized change depends on how much Go inlines across dodder's 22 internal
  layers. The lever is an explicit `-l` (inlining-off) build variant for
  maximal incremental-cache reuse vs. a default (inlined, faster-runtime,
  lower-reuse) variant — a per-consumer choice, not a builder limitation.
  Measuring dodder's real inlining density is the recommended next step before
  committing the production builder.
