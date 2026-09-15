---
status: experimental
date: 2026-09-15
promotion-criteria: |
  experimental → testing: every fleet consumer that named `pkgs.go` under
  the previous contract has moved to `goToolchain.go` (or to selection),
  and one registry bump has landed with no nixpkgs package rebuilding on
  any consumer host (the `go-toolchain-scope` check green, and a consumer's
  devshell re-evaluation after the bump substituting rather than building).

  testing → accepted: two release cycles with no consumer reintroducing a
  `pkgs.go` override and no lever change.
---

# Go toolchain scoped to igloo's builders

## Problem Statement

The go-toolchain(7) registry lets the fleet compile with a Go point release
the day it ships. Until now the overlay delivered it by overriding nixpkgs'
`pkgs.go` with the newest entry. That rebinds `go` for every nixpkgs package
that takes it as an input — libcap's Go bindings and everything above libcap
(gstreamer, pipewire, ffmpeg, a repo's Firefox wrapper), and every nixpkgs
`buildGoModule` tool in a devshell — none of which cache.nixos.org has for an
igloo-only compiler. Each registry bump therefore rebuilt that chain from
source on every consumer host. On 2026-09-14 the 1.26.6 → 1.26.8 bump turned
chrest's pre-commit devshell re-evaluation into an 83-minute build that
OOM-killed a manual commit on a 16 GB host.

## Interface

- `pkgs.goToolchain` — `mkGoToolchain { }` for the newest registry entry: an
  attrset `{ go; buildGoModule; buildGoApplication; mkGoEnv; }`. `pkgs.goToolchain.go`
  is the compiler.
- `igloo.goToolchain.<system>` — the same bundle as a flake output, for a
  consumer that does not apply the overlay.
- `pkgs.go_<x>_<y>_<z>` — every registry entry, pinned, as before.
- `pkgs.go` — nixpkgs' own `go`, never overridden by the overlay.
- igloo's builders take the registry toolchain internally: godyn's per-package
  compiles, its stdlib and `godyn-lint` use `goToolchain.go`; `buildGoApplication`
  and `mkGoEnv` select it whenever it satisfies go.mod, falling back to nixpkgs'
  `go_<x>_<y>` scan only for a go.mod demanding a newer minor. Nothing selects
  nixpkgs' plain `go` implicitly.
- The flake check `go-toolchain-scope` asserts `pkgs.go` with the overlay is
  nixpkgs' derivation, `goToolchain.go` is the newest registry entry, and
  godyn's stdlib is built from it.

## Examples

    # consumer flake, overlay applied
    tc    = pkgs.goToolchain;
    go    = tc.go;
    app   = tc.buildGoApplication { pwd = ./.; src = self; };
    shell = tc.mkGoEnv { pwd = ./.; };

    # no overlay
    go = igloo.goToolchain.${system}.go;

    # a godyn / go.nix consumer changes nothing: the builder picks the toolchain
    pkgs.buildGoAuto { pname = "myapp"; src = self; inherit inputs; manifest = ./go.nix; }

**First consumer (2026-09-15).** chrest `2115086` bumped igloo `ca00931` →
`ddd99f2` with no code change (its build pins `pkgs.go_1_26`). Derivation
check on x86_64-linux: pipewire's closure reaches only nixpkgs' go 1.26.5
(pipewire → libcanberra → libcap → go), where before the bump it reached
igloo's 1.26.6; the devshell and pre-commit derivations built in minutes and
the pre-commit hook ran in seconds, against the 83-minute re-evaluation the
previous bump caused. The full gate passed in under six minutes.

## Migration

Consumers that wrote `go = pkgs.go` under the old contract silently get
nixpkgs' go once they bump igloo past this change. As of 2026-09-15 the fleet
grep finds them in conformist, papi, circus (root flake, nix-cache,
terraform-provider-nfsn), ringmaster's facade, piggy's devshell and
purse-first's `mkGoWorkspaceModule` default. Each is a one-attribute change to
`pkgs.goToolchain.go`, or dropping the attribute for buildGoApplication's
selection. Consumers pinning `pkgs.go_1_26` / `pkgs-master.go_1_26` are on
nixpkgs' minor and unaffected.

## Limitations

- A consumer that wants the registry toolchain for a nixpkgs package (say a
  `buildGoModule` tool built at the newest Go) must override that package
  itself: `pkg.override { buildGoModule = pkgs.goToolchain.buildGoModule; }`.
  The overlay no longer does it globally, by design.
- igloo's own `buildGoModule` tools (`godyn-gen`, `nixgc`) build with nixpkgs'
  go and substitute from cache; they have no toolchain-version dependence.
- Two Go compilers can now appear in one closure (nixpkgs' for its packages,
  the registry's for fleet modules). That is the intended trade: the second
  compiler builds once and is shared by every fleet module.

## Tuning Levers

| Lever | Current | Rationale | Change signal |
|---|---|---|---|
| selection default | `goToolchain.go` when it satisfies go.mod | fleet modules compile with the newest registered release | a module needs nixpkgs' exact go (unlikely; pass `go` explicitly) |
| nixpkgs `go` | untouched | keeps cache substitutes for desktop closures | never; a global override is what this FDR removes |

## More Information

- go-toolchain(7) — the registry, `mkGoToolchain`, consuming, caching.
- gomod2nix(7) § GO VERSION SELECTION — the `selectGo` order.
- FDR 0007 (godyn as the only way to build Go), FDR 0008 (go.nix manifests) —
  the builders this toolchain is scoped to.
- The 2026-09-14 chrest incident (circus/keen-aspen and chrest/grand-acacia
  session reports) — the motivating rebuild.
