---
status: superseded
superseded-by: docs/rfcs/0001-flake-input-go_mod.md
date: 2026-05-23
promotion-criteria: |
  exploring → proposed: at least one downstream Go project in this fork
  (`dagnabit`, `madder`, `maneater`, `dodder`, `chrest`, `nebulous`)
  commits to consuming a sibling Go module via the bridge — meaning a
  real `go.mod` entry resolves through a `goFlakeInputs` flake-input
  rather than through `go get` against the module proxy.

  proposed → experimental: `goFlakeInputs` lands in
  `pkgs/build-support/gomod2nix/default.nix` and the committed
  consumer above builds successfully through `buildGoApplication`
  + `mkGoEnv` end-to-end.

  experimental → testing: the lockstep-bump regression class (flake
  input rev + `go.mod` pseudo-version + `gomod2nix.toml` hash drifting
  out of sync) is empirically gone — at least one cross-repo rename
  has been observed to land in the consumer with only a `flake.lock`
  bump, no manual `go.mod` edit.

  testing → accepted: the bridge has carried at least two fork
  consumers for a release cycle, and any escape-hatch usage (manual
  `go.mod` edits to override the bridge) has been documented.
---

> **Status:** the normative interface specification for the bridge
> protocol now lives in [RFC 0001](../rfcs/0001-flake-input-go_mod.md).
> This FDR is preserved for journey context, problem-statement
> framing, and the POC findings from commit f99a3ff43278. For the
> authoritative MUST/SHOULD/MAY contract on `goFlakeInputs`,
> `mkGoEnv` parity, and multi-producer closures, see the RFC.

# Bridge Go module deps from flake inputs

## Problem Statement

Today, cross-repo Go composition in this fork is owned end-to-end by
`go.mod` / `go.sum` / `replace` directives; Nix only packages the
result Go has already resolved. Bumping a sibling Go module (e.g.
`dodder` → `madder`) requires editing **three** places in lockstep:

1. `go.mod`'s pseudo-version in the consumer's `require` line.
2. `gomod2nix.toml`'s NAR hash for that module.
3. `flake.lock`'s rev of the sibling-module input.

When any of these three drifts, the build still succeeds (each layer
is internally consistent) but the binary runs against the wrong
version of the sibling. The motivating regression — madder's
`dodder-blob_store-config` → `blob_store-config` rename — landed
exactly this way: the flake input bumped, but `go.mod`'s pin lagged
into a runtime panic. The drift class is silent at every gate.

The deeper friction is **the codegen-at-Nix-build-time vision**: when a
producer flake's output is itself a generated Go source tree (e.g.
`dagnabit`'s graph export, `tommy`'s code generation), there is no
Nix-native path to feed that output into a consumer's Go module
without round-tripping through Go's module system. Today consumers
re-run codegen as a `preBuild` shell fragment, or — worse — as a
manual step outside Nix during dev loops. The result isn't cached, and
the divergence surface grows.

The bridge collapses the lockstep: only the flake input rev matters;
the merged `go.mod`'s replace points at the new store path
automatically, and `gomod2nix.toml` only tracks the *organic* surface.

## Interface

See [RFC 0001 § Consumer interface](../rfcs/0001-flake-input-go_mod.md#consumer-interface-goflakeinputs).

## Examples

A downstream consumer that depends on a sibling Go module would
migrate roughly as follows:

```nix
# Before — manual lockstep:
{ pkgs, inputs, ... }:
let
  madder = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    subPackages = [ "cmd/madder" ];
    modules = ./gomod2nix.toml;
    # `go.mod` has a `require github.com/amarbel-llc/dodder v0.0.0-...`
    # pseudo-version that has to be hand-synced with inputs.dodder's rev,
    # and a `gomod2nix.toml` entry with a hand-synced NAR hash.
  };
in {
  packages.default = madder;
}

# After — bridge:
{ pkgs, inputs, ... }:
let
  madder = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    subPackages = [ "cmd/madder" ];
    modules = ./gomod2nix.toml;
    goFlakeInputs = {
      "github.com/amarbel-llc/dodder" = inputs.dodder;
    };
  };
in {
  packages.default = madder;
}
```

The consumer's `gomod2nix.toml` loses the `dodder` entry entirely.
`go.mod` still carries the `require` line (Go's parser needs *some*
version) with a sentinel pseudo-version. Bumping dodder is now a
`nix flake update --input dodder` away.

## Multi-producer closures: `follows` + passthru inheritance

See [RFC 0001 § Multi-producer closures](../rfcs/0001-flake-input-go_mod.md#multi-producer-closures-follows--passthru-inheritance).

## POC findings (commit f99a3ff43278, `zz-pocs/goflake-poc/`)

A three-phase probe of the bridge pattern's foundation:
`require <module> v0.0.0-<sentinel-pseudo>` +
`replace => ./.flake-inputs/<name>`, with the nix builder symlinking
the flake input's source into `.flake-inputs/<name>` at build time.

1. **Bare `go build`: PASS.** The minimum syntactically-valid sentinel
   pseudo-version `v0.0.0-00010101000000-000000000000` is accepted by
   `module.CanonicalVersion` (and thus `modfile.Parse` with a nil
   fixer); the symlinked local-path replace resolves cleanly; no
   `go.sum` entry is required for the replaced module.

2. **`buildGoModule`: PASS** with two non-default knobs:
   `vendorHash = null` + `proxyVendor = true` (suppresses
   buildGoModule's auto-`-mod=vendor`; see
   `nixpkgs/pkgs/build-support/go/module.nix` line ~232) and
   `subPackages = ["."]` (prevents subpackage discovery from walking
   into the symlinked replace target, which is a separate Go module).
   `preBuild` symlinks the flake input's store path into
   `.flake-inputs/<name>` at build time.

3. **`buildGoApplication`: FAIL.** This is the concrete blocker
   `goFlakeInputs` must address. The existing `localReplaceCommands`
   block (`pkgs/build-support/gomod2nix/default.nix:198-205`):

   ```nix
   mkdir -p $(dirname vendor/${name})
   ln -s ${pwd + "/${value.path}"} vendor/${name}
   ```

   evaluates `pwd + "/${value.path}"` as a Nix path at eval time and
   imports it into the store. For our pattern, `value.path =
   "./.flake-inputs/<name>"`, gitignored and only created at build
   time. Result:

   ```
   error: Path '…/.flake-inputs/<name>' in the repository … is not
   tracked by Git.
   ```

   No `proxyVendor`-equivalent escape hatch exists on
   `buildGoApplication`.

### Implications for the implementation

Any implementation must avoid the eval-time path import for synthetic,
flake-input-driven replaces. Two natural shapes:

- **Eval-time substitution** (preferred). Accept `goFlakeInputs` as
  `{ "<go-module-path>" = <flake-input-derivation>; }`. Inject those
  entries into `mkVendorEnv` *parallel to* `goMod.replace`, but with
  the symlink target taken directly from the flake-input derivation
  rather than reconstructed via `pwd + "/${value.path}"`. The synthetic
  entries never need to exist on the source filesystem at eval time.
  At build time, a small `postPatch` step copies the merged `go.mod`
  into the unpacked source so that `go build -mod=vendor`'s
  source-tree checks see the synthetic `require` / `replace` lines;
  this delivery mechanism is load-bearing but doesn't undermine the
  eval-time substitution shape — the merge itself still happens at
  eval time.
- **Build-time deferral.** Move the local-replace symlinking out of the
  vendor-FOD and into a `postUnpack`/`preBuild` phase of the main
  derivation, mirroring `buildGoModule`'s approach. More invasive but
  decouples the timing entirely.

The eval-time substitution shape is the smaller change and matches the
"intermediate Nix-eval-time derivation runs `go mod edit -replace=...`"
framing. The POC pinpoints the exact lines that need to change.

Tracking issue: [amarbel-llc/nixpkgs#32](https://github.com/amarbel-llc/nixpkgs/issues/32).

## Limitations

For the protocol-level limitations (caller-managed `require` line,
transitive deps, source-only inputs, no `go build` outside Nix,
`mkGoEnv` parity), see
[RFC 0001 § Limitations](../rfcs/0001-flake-input-go_mod.md#limitations).

POC-specific items that surfaced during this FDR's exploration and
remain to verify against any landed implementation:

- **No interaction yet defined with `buildGoRace` / `buildGoCover`.**
  These wrappers `overrideAttrs` on a `buildGoApplication`-produced
  derivation. They *should* be unaffected by `goFlakeInputs` (the merge
  happens before they wrap), but this needs concrete verification
  against the bridge as implemented.

## More Information

- Producer-side counterpart:
  [`0004-go-pkgs-producer-convention.md`](./0004-go-pkgs-producer-convention.md).
  Defines the `packages.${system}.go-pkgs` flake-output convention and
  `mkGoPkgs` middleware helper that supply the source trees this FDR's
  `goFlakeInputs` consumes. The two FDRs form the end-to-end
  cross-flake Go composition story.
- POC: `zz-pocs/goflake-poc/` in this repo. Commit f99a3ff43278.
- Tracking issue:
  [amarbel-llc/nixpkgs#32](https://github.com/amarbel-llc/nixpkgs/issues/32).
- Originating exploration:
  [amarbel-llc/nixpkgs#12](https://github.com/amarbel-llc/nixpkgs/issues/12)
  ("flake input as canonical Go module source"). Its strategic framing
  and resolved sub-decisions were absorbed here; the issue stays open
  as a tracking surface for the next trigger event.
- Sibling FDR: `docs/features/0001-numtide-go2nix-overlay-builder.md`
  originally carried this material as its *Path A — Bridge*
  subsection. The bridge was extracted here when the per-package
  caching ambition (Path B) and the bridge developed distinct
  promotion tracks. If `numtide/go2nix` adoption becomes the durable
  Go-build foundation in this fork (and per-package caching subsumes
  the lockstep problem), this FDR may become superseded by 0001's
  successor; until then, the bridge is the primary route.
- Adjacent infra issues surfaced during the originating investigation:
  [amarbel-llc/dodder#125](https://github.com/amarbel-llc/dodder/issues/125),
  [amarbel-llc/dodder#126](https://github.com/amarbel-llc/dodder/issues/126),
  [amarbel-llc/clown#39](https://github.com/amarbel-llc/clown/issues/39).
- Codegen tools relevant to the Nix-as-codegen-layer ambition:
  `amarbel-llc/dagnabit`, `amarbel-llc/tommy`. A future FDR may
  capture the codegen-as-Nix-derivation pattern independently of the
  choice of Go builder.
- Downstream consumers expected to evaluate against this FDR:
  `dagnabit`, `madder`, `maneater`, `dodder`, `chrest`, `nebulous`.
