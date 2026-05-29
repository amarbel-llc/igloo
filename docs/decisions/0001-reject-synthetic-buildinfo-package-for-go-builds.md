---
status: rejected
date: 2026-04-24
decision-makers: Sasha F
informed: amarbel-llc engineering
---

# Reject synthetic `buildinfo` Go package in `buildGoApplication`

## Context and Problem Statement

Across amarbel-llc Go projects, build-time identity (version, commit) is
exposed via the Go community's conventional pattern: a `var` in `package
main` (or a dedicated `buildinfo` package) set at link time with
`-ldflags "-X …"`. Madder's `go/internal/0/buildinfo` shows the pattern
can be reused across multiple binaries in one module. The proposal in
[#5](https://github.com/amarbel-llc/nixpkgs/issues/5) was for
`buildGoApplication` (in this fork) to **synthesize** such a package at
build time — writing a generated `buildinfo.go` containing `const`
values — so consumers would not need to wire ldflag paths at all.

## Decision Drivers

* Reduce per-project boilerplate (ldflag path wiring, `var` placeholders).
* Prefer compile-time `const` over link-time `var` for type safety and
  inlining.
* Keep parity with upstream nixpkgs `buildGoModule` so downstream
  consumers can switch builders with minimal friction.
* Avoid invalidating the Go compile cache unnecessarily.
* Match what the broader Go ecosystem already does, so contributors can
  transfer intuition from other projects.

## Considered Options

* **A. Synthesize a `buildinfo` package with `const` values** at build
  time (the proposal).
* **B. Keep the ldflag `-X` pattern**, optionally adding a
  `buildinfoPkg` attr to `buildGoApplication` so callers pass the import
  path instead of hand-assembling `-X main.version=…`.
* **C. Lean on `runtime/debug.ReadBuildInfo`** (Go 1.18+) for anything
  expressible via module metadata, and ldflags for the rest.

## Decision Outcome

Chosen option: **B — keep ldflags, with optional ergonomic wrapping**,
because option A introduces cache-invalidation and sandbox-write costs
that no mainstream Go build system accepts, accepting that ldflags
remain string-only and silently tolerate typos.

### Consequences

* Good, because we stay aligned with every major Go project and every
  mainstream build system (rules\_go `x_defs`, nixpkgs `buildGoModule`,
  upstream `gomod2nix`, Buck2, Pants), which all use `-X` stamping.
* Good, because ldflag stamping only relinks the final binary; a
  generated `buildinfo.go` imported broadly would invalidate the
  compile cache for every importer on every bump.
* Good, because we avoid writing generated Go source into the source
  tree (which would conflict with Nix's read-only sandbox) or into a
  synthetic module (which would require intercepting module resolution).
* Bad, because `-X` remains string-only, targets `var` not `const`, and
  silently no-ops on a typo'd symbol path. We accept this because the
  Go team chose `ReadBuildInfo` as the fix direction, not generated
  `const` files.
* Neutral, because multi-binary modules can still share a `buildinfo`
  package — it just uses `var` set by ldflags, same as everyone else.

### Confirmation

This ADR itself is the confirmation. No code change is required to
"implement" a rejection. If someone revisits the idea, they should
supersede this ADR rather than silently add the feature.

## Pros and Cons of the Options

### A. Synthesize a `buildinfo` package with `const` values

* Good, because values are real compile-time constants — typed, inlined,
  not limited to strings.
* Good, because consumers import a stable package path and never touch
  ldflags.
* Bad, because generating a file imported by many packages invalidates
  the compile cache for each on every version bump. Bazel's `rules_go`
  explicitly cites this as the reason to prefer `x_defs` over codegen.
* Bad, because writing into the source tree conflicts with Nix's
  read-only sandbox; the alternative (a synthetic module injected into
  `GOFLAGS`/replace directives) is a deep, fragile hook.
* Bad, because no prior art exists to point contributors at — every
  surveyed Go project (Kubernetes, Terraform, Consul, Vault, Prometheus,
  Grafana, CockroachDB) uses `var` + `-X`, often with
  `//go:embed VERSION` for the semver.
* Bad, because no Nix/Bazel/Buck/Pants builder ships this feature, so we
  would be maintaining a one-off divergence with no upstream path.

### B. Keep ldflags, with optional `buildinfoPkg` ergonomic attr

* Good, because it matches established convention — contributors
  transfer intuition from any other Go project.
* Good, because ldflag stamping only relinks; compile cache stays warm.
* Good, because it composes with `runtime/debug.ReadBuildInfo` for the
  subset of fields that tool can supply.
* Neutral, because the ergonomic attr is additive — projects that
  already spell out their `-X` paths are unaffected.
* Bad, because values are stringly-typed `var`s; typos silently no-op.
* Bad, because the wrapper only hides the string plumbing; it does not
  change the underlying mechanism.

### C. Lean on `runtime/debug.ReadBuildInfo`

* Good, because it is the Go team's stated direction (accepted
  proposals [golang/go#37475](https://github.com/golang/go/issues/37475)
  and [golang/go#50603](https://github.com/golang/go/issues/50603)).
* Good, because no wrapper is needed for module-version data.
* Bad, because it cannot carry arbitrary build-system values (e.g. a
  non-VCS commit, a build ID, a downstream label). For those, ldflags
  are still required.
* Neutral, because in practice this coexists with option B rather than
  replacing it.

## More Information

* [#5](https://github.com/amarbel-llc/nixpkgs/issues/5) — originating
  issue ("explore: synthetic buildinfo package for all amarbel-llc Go
  projects").
* [amarbel-llc/madder#40](https://github.com/amarbel-llc/madder/issues/40)
  — migration where the current `buildinfo.Set(v, c)` workaround was
  discussed.
* `gomod2nix(7)` — documents the `main.version` / `main.commit` ldflag
  pattern that remains canonical in this fork.
* Survey of mainstream practice (Kubernetes `component-base/version`,
  HashiCorp `VersionMetadata`, Prometheus `prometheus/common` version
  package, Grafana Makefile ldflags, CockroachDB `pkg/build`) — all use
  `-X`-stamped `var`s, none generate `const` files.
* Survey of build systems (nixpkgs `buildGoModule`,
  `nix-community/gomod2nix`, `rules_go` `x_defs`, Buck2 prelude, Pants)
  — all expose ldflag stamping, none synthesize a buildinfo package.
