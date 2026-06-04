---
status: exploring
date: 2026-05-01
promotion-criteria: |
  exploring → proposed: a consumer in this fork's downstream Go projects
  (dagnabit, madder, maneater, dodder, chrest, nebulous) commits to using
  per-package caching as a build target, AND the plugin-loading story is
  worked out for the fork's devshells (or experimental-mode is judged
  acceptable as the only supported path), AND the cross-flake Go-module
  composition question (see Limitations) has at least a working answer
  for the dagnabit-codegen-as-Nix-derivation use case — since that's
  the load-bearing motivation beyond raw cache reuse.

  proposed → experimental: working overlay attrs land behind a flake input,
  with at least one downstream repo building successfully against
  `pkgs.go2nix.buildGoApplication`.

  experimental → testing: measurable per-package cache reuse demonstrated
  on at least one fork repo, vs. the equivalent buildGoApplication build,
  with numbers captured in this FDR.

  testing → accepted: numtide upstream removes the "experimental"
  designation OR the fork's consumers explicitly accept the upstream-churn
  risk and we document a pinning strategy.
---

# Numtide go2nix as an overlay build helper

## Problem Statement

The fork's Go projects (`dagnabit`, `madder`, `maneater`, `dodder`, `chrest`,
`nebulous`) are multi-package repos: each holds several `cmd/*` binaries plus
shared library packages. The current build path (`buildGoApplication` from
the vendored `gomod2nix`) treats each application as an opaque unit — when a
single leaf package changes, every binary built from the same module
rebuilds, even if the change can't possibly have affected most of them.

`numtide/go2nix` is a Nix-native Go builder that models the **package
graph**, not just the module set: the lockfile pins modules, but Nix
derivations are produced per-package. Architecturally similar to Bazel's
`rules_go`, with a much narrower scope. For monorepos with several binaries
sharing a heavy dependency graph, the unit of cache reuse moves from
"the whole app" to "individual Go packages."

A second motivation, beyond cache reuse, is to push **codegen into the
Nix layer**. Several of the fork's Go projects depend on codegen tools
that today are invoked at dev time and have their output checked into
git — `amarbel-llc/purse-first:cmd/dagnabit/`'s `export` subcommand
generates facade source trees under `go/pkgs/<facade>/`, regenerated
by hand via a `just generate-facades` recipe in each consuming repo.
The intent is to move this work into the Nix build path so the
generated trees are derivation outputs, not committed artifacts.

The **producer-side mechanism** for that move is captured by
[FDR-0004 (`go-pkgs producer convention + middleware`)](./0004-go-pkgs-producer-convention.md):
producer flakes expose `packages.${system}.go-pkgs` as a derivation
whose output is the (possibly codegen-passed) Go source tree, with
dagnabit as one example middleware. The **consumer-side mechanism** is
already implemented by [FDR-0003 (`bridge-go-flake-inputs`)](./0003-bridge-go-flake-inputs.md):
`buildGoApplication`'s `goFlakeInputs` arg ingests producer flake
outputs as Go module sources. Together they deliver the
codegen-as-derivation flow described in this section's first
paragraph.

What FDR-0003 and FDR-0004 do **not** address is *per-package cache
reuse* across the bridge. When a producer's `go-pkgs` output rotates
(any source change in the producer's tree, including a single facade),
the consumer's vendor symlink points at a new store path and Go's
stock toolchain rebuilds at module-path-version granularity — not
package granularity. That's where numtide go2nix's package-graph
caching becomes load-bearing. The codegen ambition still motivates
this FDR; what's changed is that the cross-flake delivery half is
solved, and per-package caching is now the only remaining open piece.
The ambition generalizes — `amarbel-llc/tommy` and other codegen
pipelines should follow the same shape once one consumer commits.

This FDR exists so downstream repos in the fork can point to a single
write-up when deciding whether to migrate or wait. **Status is
`exploring`**: numtide flags the project as experimental upstream
(API and lockfile may change without notice), so this fork has not
committed to shipping it.

## De-risk findings (2026-06-03)

A focused investigation of upstream `numtide/go2nix` (default-branch
HEAD `6c2df42e6d49afff0c6c6af17c5138d1293d4146`, latest commit
2026-05-07; **no tags or releases**; README banner: "Experimental —
APIs and lockfile formats may change without notice") resolved three of
the open questions gating this FDR. The findings below resolve the
corresponding open questions raised under *Interface*, *Cross-flake
Go-module composition* (Path B), and *Limitations*. Pinning a flake
input to a commit SHA is mandatory given the no-semver, no-release
posture.

### Plugin-loading story — resolved: prefer experimental mode, not the plugin

The default builder's evaluator plugin (`libgo2nix_plugin.so`,
registering `builtins.resolveGoPackages`) **cannot be wired in by an
overlay or a flake.** Every supported load path mutates host evaluator
config: `nix.conf`'s `plugin-files`, NixOS `nix.settings.plugin-files`,
or per-invocation `--option plugin-files`. Flake `nixConfig.plugin-files`
does **not** work — `plugin-files` is outside Nix's fixed five-key
`nixConfig` allowlist (`bash-prompt*`, `flake-registry`,
`commit-lock-file-summary`), so it is ignored unless the host enables
`accept-flake-config`. The plugin's ABI is also version-locked to the
exact evaluating Nix (it pins `nixVersions.nix_2_34`); a mismatch fails
with `attribute 'resolveGoPackages' missing`.

`buildGoApplicationExperimental` is the plugin-free alternative. It
requires Nix ≥ 2.34 (asserted in `nix/dynamic/default.nix`) plus the
`recursive-nix`, `ca-derivations`, and `dynamic-derivations` experimental
features, and sets `requiredSystemFeatures = ["recursive-nix"]` on the
builder. It is actively exercised upstream (dedicated dynamic-mode test
fixtures + a shared runner), not vestigial.

**Position:** for this fork — already experimental-feature-friendly in
its devshells — expose `buildGoApplicationExperimental` and document the
Nix 2.34 + experimental-features floor, rather than ship the plugin and
ask every host to set `plugin-files`. Caveat: neither mode is fully
overlay-self-contained — the experimental path still needs host-level
experimental-features and the `recursive-nix` system-feature, which are
*also* outside the flake-`nixConfig` allowlist. The experimental path
trades a brittle version-locked `.so` for declarative feature flags the
fork's hosts likely already carry. The residual risk is the maturity of
the recursive-nix / CA / dynamic-derivations stack itself, not go2nix's
code.

### Path B (native `resolveGoPackages` across flakes) — resolved: NOT viable

`builtins.resolveGoPackages` takes a **source tree**, runs `go list`
over it at eval time, and resolves the **whole transitive package graph
from that single `src`.** There is no producer/consumer composition
primitive, no flake-output type representing "a Go package graph," and no
`replace => <nix store path>` mechanism. go2nix's `replace` handling has
exactly two branches — a local `./`/`../` path *inside `src`*, or a
fork-swap keyed by module version + NAR hash from the proxy — and a Nix
store path matches neither. Cross-flake reuse exists **only** via Nix's
input-addressed binary cache (identical module FODs / package `.a`
derivations dedupe in `/nix/store`), which is automatic and orthogonal to
flake boundaries — not producer→consumer graph passing.

**This settles the binary framing in *Path B — Native* below in favour
of its pessimistic branch:** Path A (the bridge, already implemented per
RFC-0001) is the durable cross-flake answer; go2nix's value narrows to
**per-package cache reuse within a single flake** (shared opportunistically
across flakes by the binary cache when inputs match identically). The
codegen-as-derivation delivery is owned by the bridge + `mkGoPkgs`;
go2nix does not subsume it.

*Caveat:* the verdict rests on docs + the `nix/dag` builder + the Rust
resolver source, not an executed build. The one untested edge is a
store-path `replace`; predicted (high confidence) to be ignored by
`walk_local_replace_dirs` (non-`./` target) and/or dropped by the dag
`mainSrc` filter (target outside `src`). Building a consumer with such a
replace, plugin loaded, would settle it conclusively.

### buildGoRace / buildGoCover composition — resolved: incompatible as written

The fork's `buildGoRace` / `buildGoCover`
(`pkgs/build-support/gomod2nix/default.nix`, ~L978 / ~L1019)
`overrideAttrs` a `buildGoApplication` derivation, mutate the bash
`buildFlagsArray` (consumed by gomod2nix's `goBuildHook` → cmd/go), and
override `checkPhase` to run `go test -race` / capture coverage. go2nix
builds each package with `go tool compile` / `go tool link` from JSON
manifests — there is **no `goBuildHook`, no `buildFlagsArray`, no
per-binary `go` invocation** — so the injected `preBuild` lines would be
inert and the `checkPhase` override would clobber go2nix's
`go2nix test-packages` mechanism. The wrappers cannot port unchanged.

go2nix exposes `gcflags` / `ldflags` / `tags` / `pgoProfile` /
`packageOverrides` / scope-level `goEnv` as injection points.

- **`-race`:** partial only. go2nix propagates a `-race` smuggled through
  `gcflags` to both `go tool compile` and `go tool link` (its
  `extractSanitizerFlags` path), **but the stdlib is built once without
  `-race`**, keyed on `(go version, goEnv)` with race-ness not in the
  key. With no race-instrumented stdlib variant, an end-to-end `-race`
  build is **not supported** and would require an upstream go2nix change
  (a `-race` stdlib plus a first-class `race` knob, not an
  `overrideAttrs`). *(stdlib-missing-`-race` is verified by source; the
  resulting breakage is inferred, not reproduced.)*
- **`-cover`:** **no support at all.** Coverage instrumentation is a
  source-rewrite pass cmd/go owns before compile; go2nix bypasses cmd/go,
  so `-cover` cannot be expressed as a compile flag. It needs a new
  upstream instrumentation stage. The fork wrapper's GOCOVERDIR /
  `go tool covdata textfmt` runtime-capture half could be reused as a
  post-build phase once go2nix can emit instrumented binaries.

Adjacent gap surfaced during this work: neither `buildGoRace` nor
`buildGoCover` is documented in any scd man page under
`pkgs/build-support/gomod2nix/` (only `gomod2nix.7.scd`,
`goSourceFilter.7.scd`, `mkGoPkgs.7.scd` exist).

### Net effect on promotion

Two of the three `exploring → proposed` gates are now cleared: the
plugin-loading story is resolved (experimental mode; plugin rejected for
overlay delivery), and the cross-flake composition question is answered
(Path B not viable; the bridge is durable; go2nix = per-package caching).
The remaining gate is strategic, not research: **a downstream consumer
must commit to per-package caching as a build target.** Until then this
FDR stays `exploring`.

## POC validation (2026-06-04)

Rather than adopt `numtide/go2nix`, a throwaway POC (`zz-pocs/godyn-poc/`,
with the dodder inlining measurement in `zz-pocs/godyn-dodder/`) built a
**native, igloo-owned per-package Go builder end to end** — recursive-nix +
ca-derivations + dynamic-derivations, no `numtide/go2nix` dependency — and
answered the open R6 question empirically. (Decision recorded this session:
roll our own instead of consuming numtide, since its API/lockfile are
unreleased and plugin-bound.)

**What works (M1–M4, all pass on this box — Determinate Nix 2.34.6):**

- A shared stdlib derivation (`GODEBUG=installgoroot=all go install --trimpath
  std` → per-package `.a` + importcfg).
- A text-mode CA wrapper whose `$out` *is* the final link `.drv`, resolved at
  eval time via `builtins.outputOf`; a build-time resolver that discovers the
  graph with `go list`, registers one **floating-CA derivation per package**
  via `nix derivation add`, and builds with `go tool compile` / `go tool link`.
- Multi-package first-party graphs (topo order + per-package importcfg wiring),
  and **third-party modules via a fixed-output `go mod download` + a
  synthesised GOMODCACHE** (extracted tree symlinked at `<epath>@<ever>/` +
  `cache/download/<mod>/@v/{.mod,.info,.ziphash,.lock}`, ziphash = lockfile h1).
- Two non-obvious gotchas, resolved and recorded: `nix derivation add` does not
  auto-inject `$out` (set it to `hashPlaceholder("out")` =
  `/`+nixbase32(sha256("nix-output:out"))); output key-sets are matched exactly
  (`{method,hash}` FOD vs `{method,hashAlgo}` floating-CA).

**The R6 verdict (M5, decisive).** Per-package CA isolation is **real but
bounded by Go's cross-package inlining.** With inlining disabled
(`//go:noinline`) a private change to a leaf package leaves a dependent's
compiled `.a` **byte-identical** (same CA store path → cache hit). With inlining
on, the leaf's body is inlined into the dependent, so the change cascades. The
iface/export-data split does **not** fix this — Go's export data carries inline
bodies — so **`-gcflags=all=-l` is the only full-isolation lever** (runtime-perf
cost).

**dodder inlining density (`zz-pocs/godyn-dodder/`).** 6,753 inlinable
functions; **14,236 inlined call sites**, dominated by dodder's own foundational
generic packages (`collections_slice` alone ≈ 30%; the generic-container +
leaf-utility families are the bulk; stdlib ≈ 28%). These are low-churn, so the
cache win is **real for typical high-layer edits, bounded for foundational
edits**. A production builder should offer an inlining-off variant for CI /
test-loop builds.

**Implication for promotion.** Feasibility is no longer in doubt: the
plugin-loading story (recursive-nix, not the C++ plugin), the cross-flake
question (the bridge / RFC-0001), and the per-package mechanics (this POC) are
all resolved or proven. What remains for `exploring → proposed` is unchanged in
*kind* but now **low-risk engineering**: a production-quality overlay attr (vs.
the throwaway resolver), `goFlakeInputs`-bridge integration, the
`buildGoRace`/`buildGoCover` restructure, and a downstream consumer (dodder is
the natural first, given its build cost) committing to it.

## Interface

The intent (not yet implemented) is to expose `numtide/go2nix` as an
**overlay-only** addition, alongside — not replacing — `buildGoApplication`
from the vendored `gomod2nix`. The two helpers would coexist; consumers
opt in per-project.

The exposed surface from `overlays/amarbel-packages.nix` would be:

| Attribute | Source | Purpose |
|-----------|--------|---------|
| `pkgs.go2nix.buildGoApplication` | numtide goEnv | Per-package builder, default mode (requires Nix plugin) |
| `pkgs.go2nix.buildGoApplicationExperimental` | numtide goEnv | Per-package builder, recursive-nix mode (requires Nix ≥ 2.34 + experimental features) |
| `pkgs.go2nix-cli` | numtide flake | The `go2nix generate` / `go2nix check` CLI |
| `pkgs.go2nix-nix-plugin` | numtide flake | The `libgo2nix_plugin.so` Nix evaluator plugin |

Naming notes:

- `pkgs.go2nix` is namespaced as an attrset rather than flat to avoid
  shadowing `pkgs.buildGoApplication` (the gomod2nix one).
- `pkgs.go2nix-cli` is split out because `pkgs.gomod2nix` already holds
  the gomod2nix CLI — both can't claim the same flat name.
- The CLI ships its own lockfile format (`go2nix.toml`), incompatible with
  `gomod2nix.toml`. Projects that adopt this builder maintain a `go2nix.toml`
  separate from any existing `gomod2nix.toml`.

The plugin (`pkgs.go2nix-nix-plugin`) provides
`builtins.resolveGoPackages`, which the default-mode builder calls during
evaluation. The overlay can ship the `.so`, but **loading it is host-side
evaluator config**, not something an overlay can do. Users must add it
to `nix.conf` via `plugin-files = ...` or pass `--option plugin-files
<path>` per invocation. NixOS users would set
`nix.settings.plugin-files`.

`buildGoApplicationExperimental` avoids the plugin entirely by using
recursive-nix with content-addressed derivations and dynamic derivations.
It needs Nix ≥ 2.34 with three experimental features enabled
(`recursive-nix`, `ca-derivations`, `dynamic-derivations`). For a fork
that's already comfortable with experimental Nix features in its
devshells, this is arguably a cleaner integration path.

## Examples

A downstream consumer (e.g. `madder`) would migrate its `go/default.nix`
roughly as follows:

```nix
# Before — gomod2nix path:
{ pkgs, ... }:
let
  madder = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    subPackages = [ "cmd/madder" "cmd/madder-cache" "cmd/madder-gen_man" ];
    modules = ./gomod2nix.toml;
  };
in {
  packages.default = madder;
}

# After — go2nix path (illustrative, not yet implemented):
{ pkgs, ... }:
let
  madder = pkgs.go2nix.buildGoApplication {
    pname = "madder";
    src = ./.;
    goLock = ./go2nix.toml;
    version = "0.1.0";
  };
in {
  packages.default = madder;
}
```

To regenerate the lockfile after a `go.mod` change:

```bash
$ go2nix generate .         # writes ./go2nix.toml from go.mod / go.sum
$ go2nix check              # validates the lockfile is in sync
```

To use the default builder, the evaluator must have the plugin loaded.
For a one-off invocation:

```bash
$ nix build \
    --option plugin-files \
    "$(nix build --no-link --print-out-paths nixpkgs#go2nix-nix-plugin)/lib/nix/plugins/libgo2nix_plugin.so" \
    .#default
```

For permanent setup, in `~/.config/nix/nix.conf` (or `nix.settings` on
NixOS):

```
plugin-files = /nix/store/...-go2nix-nix-plugin/lib/nix/plugins/libgo2nix_plugin.so
```

## Cross-flake Go-module composition

The codegen-at-Nix-build-time vision (see Problem Statement) hinges
on a question bigger than the choice between gomod2nix and go2nix:
**how does a Go module exposed by one Nix flake get imported into
another Go module's Nix flake?** Today, cross-repo Go composition is
owned end-to-end by `go.mod` / `go.sum` / `replace` directives; Nix
only packages the result Go has already resolved. When the producer
flake's output is itself a generated Go source tree (e.g.
`dagnabit`'s graph export, `tommy`'s code generation), there is no
Nix-native path to feed that output into a consumer's Go module
without round-tripping through Go's module system.

Two strategies are in play, at different points on the ambition axis.

### Path A — Bridge: synthesize `go.mod` replace directives from flake inputs

**Extracted to its own FDR.** See
[`0003-bridge-go-flake-inputs.md`](./0003-bridge-go-flake-inputs.md).
The bridge has its own promotion track and POC validation
(`zz-pocs/goflake-poc/`, commit f99a3ff43278) and is no longer
gated on the broader numtide go2nix exploration in this document. If
per-package caching (path B) becomes the durable Go-build foundation
in this fork and subsumes the lockstep problem the bridge solves,
FDR-0003 may become superseded by this document's successor. Until
then, the two paths progress independently.

### Path B — Native: `resolveGoPackages` across flake inputs

> **Resolved (2026-06-03): not viable.** See *De-risk findings* above —
> `resolveGoPackages` resolves the whole graph from a single `src` and
> has no cross-flake composition primitive. The pessimistic branch below
> is the answer; Path A (the bridge) is durable.

The fully-Nix-native path. numtide go2nix's plugin exposes
`builtins.resolveGoPackages`, which the default-mode builder calls
during evaluation. Whether that resolution can reach across flake
inputs — whether a producer flake can expose its Go package graph as
a Nix value the consumer's `resolveGoPackages` will consume, without
each flake re-vendoring the full transitive package graph — is not
clear from the upstream docs. This is the most consequential
unanswered question for the codegen ambition and is logically prior
to migrating any fork repo to go2nix.

If path B is viable, path A becomes a transitional shim. If path B
is fundamentally limited (e.g. `resolveGoPackages` cannot cross
flake boundaries), path A is likely the durable answer and go2nix's
value proposition narrows to per-package cache reuse within a single
flake.

## Limitations

- **Upstream is experimental.** numtide/go2nix's README explicitly warns
  that "APIs and lockfile formats may change without notice." A fork that
  ships this overlay attr is opting into upstream churn — every numtide
  release may require lockfile regeneration and possibly call-site
  adjustments. There is no semver discipline being promised.

- **Default mode requires a Nix C++ plugin.** This is fundamentally
  outside what an overlay can manage. Each consumer of the overlay must
  add `plugin-files` to their host's `nix.conf` (or NixOS configuration).
  Devshells alone cannot wire this in; the plugin has to be loaded by the
  evaluator at evaluation time, before any flake code runs.

- **Experimental mode locks consumers to recent Nix.** The plugin-free
  `buildGoApplicationExperimental` requires Nix ≥ 2.34 with
  `recursive-nix`, `ca-derivations`, and `dynamic-derivations` experimental
  features enabled. This may not be acceptable in every consumer's CI or
  contributor environment.

- **Lockfile divergence.** `go2nix.toml` and `gomod2nix.toml` are
  schema-incompatible. A project that adopts go2nix without removing its
  gomod2nix.toml has to keep both in sync manually — or pick one and
  delete the other. There is no migration tool today.

- **Name collision on `buildGoApplication`.** numtide's function and the
  vendored gomod2nix function share a name. The overlay must namespace
  numtide's under `pkgs.go2nix.*` to keep both available, which means
  call sites are visually distinct but readers may still confuse them.

- **No interaction yet defined with `buildGoRace` / `buildGoCover`.**
  This fork added `buildGoRace` and `buildGoCover` as ergonomic wrappers
  around the gomod2nix `buildGoApplication` (see
  `pkgs/build-support/gomod2nix/default.nix` and the More Information
  section). Whether and how those wrappers should compose with
  numtide's per-package builder is unanswered. The naive shape
  (`overrideAttrs` on the per-package leaf derivation) likely doesn't
  work, since per-package builds use `go tool compile/link` rather than
  `go install`, and `-race` / `-cover` interact differently at that
  level. Concrete experimentation needed before a recommendation.

- **Per-package caching's win is monorepo-shaped.** The benefit only
  shows up when (a) the project has many packages, (b) builds are run
  often enough that cache reuse matters, and (c) changes are typically
  localized. Single-binary, single-package projects gain little.

## More Information

- Upstream: <https://github.com/numtide/go2nix> (README dated 2026, marked
  experimental)
- Related project comparison (from numtide's README): `buildGoModule`,
  `gomod2nix`, `gobuild.nix`, `nix-gocacheprog` — each occupies a
  different tradeoff point on caching granularity vs. operational
  complexity.
- Sibling work in this fork: issue
  [amarbel-llc/nixpkgs#13](https://github.com/amarbel-llc/nixpkgs/issues/13)
  added `buildGoRace` and `buildGoCover` wrappers around the gomod2nix
  `buildGoApplication` (`pkgs/build-support/gomod2nix/default.nix`).
  Composition story between those wrappers and numtide go2nix is
  open — see Limitations.
- Issue
  [amarbel-llc/nixpkgs#12](https://github.com/amarbel-llc/nixpkgs/issues/12)
  is the originating exploration of "flake input as canonical Go
  module source." Its strategic framing and resolved sub-decisions
  were absorbed into the *Cross-flake Go-module composition* section
  above; the issue stays open as a tracking surface for the next
  trigger event.
- Downstream consumers expected to evaluate against this FDR:
  `dagnabit`, `madder`, `maneater`, `dodder`, `chrest`, `nebulous`. Each
  should track its own decision in a downstream FDR pointing here.
- Codegen tools relevant to the Nix-as-codegen-layer ambition:
  `amarbel-llc/purse-first:cmd/dagnabit/` (facade export; currently
  invoked at dev time via each consumer's `just generate-facades`
  recipe, output checked into git), `amarbel-llc/tommy` (a
  generalization target — same shape applies). The
  codegen-as-Nix-derivation pattern is captured in
  [FDR-0004 (`go-pkgs producer convention`)](./0004-go-pkgs-producer-convention.md);
  this FDR retains the per-package caching motivation, which FDR-0004
  alone does not address.
