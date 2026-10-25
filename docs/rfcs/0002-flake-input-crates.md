---
status: draft
date: 2026-10-25
promotion-criteria: |
  draft → proposed: the operator has ruled on the decisions listed under
  § Decisions this draft needs, and one producer (hyphence's `rust/` or
  rust-crap) publishes the output named in § Producer interface.

  proposed → experimental: posh consumes galapagos, hyphence and rust-crap
  through `flakeInputs` under rustdyn (FDR 0009 stage 3) with no git
  dependency and no `outputHashes` for them; the igloo fixture builds a
  consumer against a producer output.
---

# RFC 0002 — flake-input-crates protocol (draft)

> **Draft.** Written by session igloo/slim-pecan on 2026-10-25 as the
> rustdyn stage 3 prerequisite the operator asked for; stage 3 itself has
> not started. Nothing below is normative until the status says so.

## Decisions this draft needs

Each one changes the text below; the recommendation is the author's.

1. **Output name.** `packages.${system}.crates` (the Rust twin of RFC 0001's
   `go-pkgs`) or `rust-crates`. Recommend `crates`: short, and the attribute
   lives beside `go-pkgs` in a polyglot producer without clashing.
2. **One output or two.** RFC 0001 publishes `go-pkgs` and `go-pkgs-test`
   because Go test files live beside the code. Cargo's unit tests live inside
   compiled files and integration tests under `tests/`, which rustdyn
   compiles only in the test variant, so one output suffices. Recommend one
   output, with `tests/`, `benches/` and `examples/` included (they are
   needed to run the producer's tests from a consumer, cost nothing in the
   normal build, and keep the output a faithful crate directory).
3. **Granularity: workspace or crate.** A producer output is a directory
   cargo can read. Recommend the workspace root (Cargo.toml, Cargo.lock,
   members), with the consumer naming the member crate it depends on
   (`subPath` as in RFC 0001); a single-crate repository is a one-member
   workspace.
4. **What the consumer's Cargo.lock says.** A flake-input crate is still a
   dependency cargo has to resolve. Options: (a) the consumer keeps a
   `[patch]` or `path` dependency pointing at a rendered location and rustdyn
   makes that location the flake input's store path at eval time; (b) the
   consumer keeps a git dependency in Cargo.toml/Cargo.lock for ambient cargo
   and rustdyn substitutes the flake input's tree for the git checkout when
   the lock's git source URL matches. Recommend (b): the checkout keeps
   working with ambient cargo (FDR 0009 decision c), the lock stays honest,
   and `outputHashes` disappears because rustdyn never fetches that git
   source (it uses the flake input). The match key is the lock's
   `source = "git+<url>?...#<rev>"` URL; the rev in the lock and the flake
   input's rev MUST agree or rustdyn fails evaluation with both values
   (RFC 0001's lockstep removal, inverted: the lock pins, the flake input
   must match).
5. **Version mismatch policy.** When the lock's rev and the flake input's rev
   differ: fail (recommended; the fix is `cargo update -p <crate>` or a flake
   input bump, both visible), or warn and prefer the flake input.
6. **Where the manifest lives.** A `cargo.nix` sibling of `go.nix` carrying
   only `flakeInputs` (FDR 0009 decision c keeps Cargo.toml authoritative),
   or an attribute of the builder call. Recommend the builder attribute for
   stage 3 (one consumer), a file when a second consumer appears.
7. **Transitive flake-input crates.** posh depends on galapagos, which
   depends on hyphence and rust-crap. Must posh declare all three, or does
   galapagos's own `crates` output carry its `flakeInputs` so posh inherits
   them (RFC 0001's depth-N inheritance)? Recommend inheritance through a
   `passthru.flakeInputs` on the producer output, mirroring RFC 0001, since
   the fleet graph is already two deep.

## Conventions

The keywords MUST, MUST NOT, SHOULD, MAY are to be interpreted as described
in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

## Abstract

The flake-input-crates protocol lets a Rust workspace built by rustdyn
(FDR 0009) take fleet crates from Nix flake inputs instead of cargo git
dependencies with `outputHashes`. It has a producer half, a conventional
flake output that is the crate's source tree, and a consumer half, a
`flakeInputs` attribute that maps a crate (or git source) to a flake input.
The flake input's rev recorded in `flake.lock` becomes the single source of
truth; Cargo.lock keeps a matching git source so ambient cargo keeps
working, and rustdyn verifies the two agree.

## Terminology

- **Producer**: a flake whose output is a Cargo workspace meant for other
  flakes' builds. Exposes `packages.${system}.crates` (decision 1).
- **Consumer**: a rustdyn (or buildRustAuto) build declaring `flakeInputs`.
- **Member crate**: one `[[package]]` of the producer's workspace, named by
  the consumer through `subPath` or `crate`.
- **Bridge**: rustdyn's eval-time step that replaces a vendored git source
  with the flake input's tree in the vendor directory and the graph.

## Producer interface

A producer MUST expose `packages.${system}.crates`: a derivation (or
filtered source) whose root is the workspace root with `Cargo.toml`,
`Cargo.lock`, every member directory and their `tests/`, `benches/` and
`examples/`, and no `target/`. It SHOULD be built with an igloo helper
(`mkRustCrates`, the `mkGoPkgs` twin) that applies the filter and attaches
`passthru.flakeInputs` (decision 7) and `passthru.members` (the member
names, from `cargo metadata --no-deps` at build time).

## Consumer interface

    pkgs.buildRustAuto {
      pname = "posh";
      src = self;
      flakeInputs = {
        # crate name -> where its source comes from
        galapagos = { input = galapagos; subPath = "v2-rust"; };
        hyphence  = { input = hyphence; subPath = "rust"; };
        rust-crap = { input = crap; subPath = "rust-crap"; };
      };
    };

For each entry rustdyn MUST: find the lock package with that name whose
source is a git URL; check the lock's rev against the input's rev (decision
5); and source the crate from `${input}/${subPath}` in place of the git
checkout, both in the vendor directory handed to `cargo metadata` and in
the per-crate derivation. A crate named in `flakeInputs` that the lock does
not know, or whose lock source is a registry, MUST fail evaluation.

## Examples

Deferred to the first consumer (posh, FDR 0009 stage 3).

## Limitations

- The consumer's Cargo.lock still names a git source, so `cargo update` for
  that crate still needs network; what disappears is the Nix-side hash
  bookkeeping and the drift between lock rev and flake rev.
- A flake input whose tree is not a Cargo workspace at `subPath` fails at
  the resolver (`cargo metadata`), not earlier.
- Cross-system limits are rustdyn's (FDR 0009 § Limitations).

## More Information

- RFC 0001 (flake-input-go_mod), the Go twin this draft mirrors.
- FDR 0009 § Staged plan, stage 3; § 1 row "bridges / archiveBridges".
- igloo#63 (Zig registry), unrelated: the toolchain is FDR 0009 decision d.
