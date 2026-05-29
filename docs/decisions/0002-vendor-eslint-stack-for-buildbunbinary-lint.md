---
status: accepted
date: 2026-04-27
decision-makers: friedenberg
adopted-in: amarbel-llc/nixpkgs#52
---

# Vendor the eslint stack for buildBunBinary lint instead of an FOD subderivation

## Context and Problem Statement

Issue amarbel-llc/nixpkgs#52 introduces an `n/no-process-exit` lint pass that runs against every entrypoint passed to `buildBunBinary` / `buildBunBinaries` at nix build time. The lint stack (`eslint`, `eslint-plugin-n`, `@typescript-eslint/parser`) needs to be available inside the sandboxed nix build. Two ways to get it there: vendor a `package.json` + `bun.lock` + `bun.nix` under `pkgs/build-support/bun2nix/lint/` and let `fetchBunDeps` materialize the closure, or fetch each package as a fixed-output subderivation at build time.

## Decision Drivers

* Reproducibility — the lint must run identically on every build, including warm cache, cold cache, and CI sandbox.
* Bump ergonomics — bumping eslint or its plugins should be mechanical, not require updating multiple sha256 hashes by hand.
* Sandbox compatibility — `bun install` cannot reach the network from a non-FOD nix derivation; some mechanism is required to stage the closure.
* Diff cost in the bun fork — avoid scattering parallel project metadata through the tree if possible.

## Considered Options

* **Vendor + check in (`pkgs/build-support/bun2nix/lint/{package.json,bun.lock,bun.nix,eslint.config.js}`)** — committed lockfile, `fetchBunDeps` stages the closure, `bun install --frozen-lockfile` runs offline.
* **FOD subderivation (`fetchurl` per package, no committed lockfile)** — each dependency is its own fixed-output derivation, hashes pinned in `default.nix`, no lockfile in the tree.

## Decision Outcome

Chosen option: **Vendor + check in**, because it gives transitive reproducibility for free via the committed `bun.lock`, accepting four extra committed files under `pkgs/build-support/bun2nix/lint/` that need refreshing on bumps.

### Consequences

* Good, because `bun install --frozen-lockfile` works offline in the nix sandbox via the existing `fetchBunDeps` path — no new sandbox plumbing.
* Good, because bumps are mechanical: `bun install` + `bun2nix` regen + commit. No hash-update dance.
* Good, because the entire transitive closure is pinned by the lockfile, so reproducibility is automatic.
* Bad, because four committed files (`package.json`, `bun.lock`, `bun.nix`, `eslint.config.js`) live as a small parallel project in the tree.
* Bad, because dependents who want to read the eslint version must look at `pkgs/build-support/bun2nix/lint/package.json` rather than a single line in `default.nix`.

### Confirmation

`nix flake check` exercises `bun2nix-lint-stack-rejects-process-exit` (via `pkgs.testers.testBuildFailure'` against `pkgs/build-support/bun2nix/tests/bin-process-exit-fail`), `test-bin-no-process-exit`, and `test-bin-process-exit-disabled`. The lint pipeline is correctly wired iff all three resolve as expected (fail / pass / pass).

## Pros and Cons of the Options

### Vendor + check in

* Good, because `bun.lock` pins the full transitive tree without per-package bookkeeping.
* Good, because the existing `fetchBunDeps` path already handles offline `bun install` in the sandbox.
* Good, because bumping is the same flow used everywhere else in the repo.
* Neutral, because the eslint stack lives under `pkgs/build-support/bun2nix/lint/` rather than inline in `default.nix`.
* Bad, because four committed files need to be refreshed together on every bump.

### FOD subderivation

* Good, because no committed lockfile in the bun fork — bumping is a one-line version change in `default.nix`.
* Good, because the lint stack lives entirely inside `default.nix`, smaller diff surface.
* Neutral, because cold-cache builds fetch each package separately rather than via one `fetchBunDeps` call.
* Bad, because every bump requires updating sha256 hashes for every fetched package — strictly more bookkeeping than regenerating a lockfile.
* Bad, because transitive deps are not pinned reproducibly unless a lockfile is also fetched, which reintroduces the vendoring problem.
* Bad, because the existing `fetchBunDeps` path does not apply — new sandbox plumbing must be written.

## More Information

* amarbel-llc/nixpkgs#52 — the issue this ADR backs; lint plumbing landed in commit 088f67bc126c (originally written in amarbel-llc/bun#7, then ported here as part of the Bun-fork dissolution tracked in amarbel-llc/nixpkgs#57).
* amarbel-llc/nixpkgs#11 — root-cause triage that motivated the lint rule (the 8 KiB stdout truncation that turned out to be `process.exit()` racing the kernel pipe drain).
