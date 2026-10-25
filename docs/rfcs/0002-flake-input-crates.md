---
status: draft
date: 2026-10-25
promotion-criteria: |
  draft → proposed: rustdyn stage 2.5 (the cargo.nix manifest, FDR 0009)
  has landed in igloo with the `flakeInputs` entry shape below exercised by
  a fixture, and one producer (hyphence's `rust/` or rust-crap) publishes
  `packages.${system}.crates`.

  proposed → experimental: posh consumes galapagos, hyphence and rust-crap
  through cargo.nix `flakeInputs` under rustdyn (FDR 0009 stage 3) with no
  git dependency, and the inherited inputs reach it through galapagos's
  `crates` output.
---

# RFC 0002 — flake-input-crates protocol (draft)

> **Draft.** Written by session igloo/slim-pecan on 2026-10-25 as the
> rustdyn stage 3 prerequisite; the operator ruled on its open decisions
> the same day (§ Decisions). Normative wording is provisional until the
> status says otherwise.

## Decisions (operator, 2026-10-25)

1. Output name: `packages.${system}.crates`.
2. One producer output, with `tests/`, `benches/` and `examples/` included.
3. Granularity: the workspace root; the consumer names the member crate
   (the godyn shape: RFC 0001 publishes one output pair per repository and
   consumers slice with `subPath`).
4. The manifest: no tracked Cargo.toml or Cargo.lock. A `cargo.nix` at the
   workspace root is authoritative (FDR 0009 decision c reversed, stage
   2.5); Cargo.toml and Cargo.lock are rendered from it at evaluation time.
   A flake-input crate is a dependency entry in cargo.nix, so there is no
   git source in any lock to keep in step and no `outputHashes`.
5. Lock/flake rev mismatch policy: not applicable, there is no tracked lock.
6. Manifest location: cargo.nix (one per workspace root).
7. Transitive flake-input crates are inherited through the producer
   output's `passthru.flakeInputs`, as RFC 0001's depth-N inheritance.

## Conventions

The keywords MUST, MUST NOT, SHOULD, MAY are to be interpreted as described
in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

## Abstract

The flake-input-crates protocol lets a Rust workspace built by rustdyn
(FDR 0009) take fleet crates from Nix flake inputs. It has a producer half,
`packages.${system}.crates` (the workspace's source tree with its rendered
manifests), and a consumer half, `flakeInputs` entries in the consumer's
cargo.nix that name a flake input and a member crate. The flake input's rev
recorded in `flake.lock` is the single source of truth for the dependency's
version; rustdyn renders it as a path dependency into the Cargo.toml and
Cargo.lock it generates, so cargo never sees a git source.

## Terminology

- **Producer**: a flake whose `packages.${system}.crates` output is a Cargo
  workspace meant for other flakes' builds.
- **Consumer**: a rustdyn (or buildRustAuto) build whose cargo.nix declares
  `flakeInputs`.
- **Member crate**: one `[[package]]` of the producer's workspace, named by
  the consumer through `subPath` (the member's directory under the output).
- **Bridge**: rustdyn's eval-time rendering of a `flakeInputs` entry as a
  path dependency on `${input}/${subPath}`.

## Producer interface

A producer MUST expose `packages.${system}.crates`: a derivation whose root
is the workspace root with the rendered `Cargo.toml`, `Cargo.lock`, every
member directory including `tests/`, `benches/` and `examples/`, and no
`target/`. It SHOULD be built with an igloo helper (`mkRustCrates`, the
`mkGoPkgs` twin) that renders the manifests from the producer's cargo.nix,
applies the filter, and attaches `passthru.flakeInputs` (the producer's own
`flakeInputs`, for inheritance) and `passthru.members` (member names and
directories, from cargo.nix).

## Consumer interface

In the consumer's cargo.nix (FDR 0009 stage 2.5 defines the file):

    {
      members."crates/posh".dependencies = {
        galapagos = { flakeInput = "galapagos"; subPath = "v2-rust"; };
        posh-term = { member = true; };
        serde = { version = "1"; features = [ "derive" ]; };
      };
    }

and in the builder call, the inputs by name:

    pkgs.buildRustAuto {
      pname = "posh";
      src = self;
      manifest = ./cargo.nix;
      inputs = { inherit galapagos hyphence crap; };
    };

For each `flakeInput` entry rustdyn MUST: resolve `inputs.<name>` to that
flake input's `packages.${system}.crates` output (falling back to the raw
input tree when the output is absent, with a warning); render the
dependency as `path = "${output}/${subPath}"` in the member's Cargo.toml
and as a path package in Cargo.lock; and merge the output's
`passthru.flakeInputs` into the consumer's set unless the consumer declares
the same name itself (consumer wins). A `flakeInput` naming an input the
builder call does not provide MUST fail evaluation naming the input.

## Examples

Deferred to the first consumer (posh, FDR 0009 stage 3).

## Limitations

- A flake input whose tree is not a Cargo workspace at `subPath` fails at
  the resolver (`cargo metadata`), not earlier.
- Inherited `flakeInputs` carry the producer's `subPath` choices; a consumer
  that needs a different member of the same input declares it itself.
- Cross-system limits are rustdyn's (FDR 0009 § Limitations).

## More Information

- RFC 0001 (flake-input-go_mod), the Go twin this draft mirrors.
- FDR 0009 § Staged plan, stages 2.5 and 3; decision (c) and its reversal.
- `docs/plans/2026-10-25-rustdyn-stage25-cargo-nix.md`, the cargo.nix design note.
