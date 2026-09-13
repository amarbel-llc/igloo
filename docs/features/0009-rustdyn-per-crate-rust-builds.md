---
status: exploring
date: 2026-09-13
promotion-criteria: >-
  To proposed: a POC builds one small fleet crate (e.g. tacky or smith) as one
  content-addressed derivation per crate from a graph derived at eval time
  (no committed generated nix), with the open questions below answered.
---

# rustdyn: per-crate content-addressed Rust builds

## Problem Statement

The fleet's Rust is built with `rustPlatform.buildRustPackage` (posh, piggy,
just-us, smith, tacky, crap, hyphence's test lane) or crane (tap). Both compile
a whole Cargo workspace and its dependencies in one or two derivations, so any
source edit rebuilds and re-tests everything, and nothing is shared between
repos that depend on the same crates. godyn solved exactly this for Go: one
content-addressed derivation per package, a package graph derived at eval time,
cross-flake composition through a producer protocol, and per-package test and
lint lanes (FDR 0007, FDR 0008). There is no Rust counterpart, and the fleet
repeats the same per-repo toolchain, vendoring and flake-lock diamond problems
(crane/rust-overlay duplicated as `crane_2`, shared `cargoLock.outputHashes`
blocks) that godyn and flake-input-go_mod removed on the Go side.

## Interface

Provisional sketch only. It mirrors godyn deliberately so that the two builders
teach one mental model; every name below is open.

- `buildRustdynWorkspace { pname, src, cargoLock ? "${src}/Cargo.lock", ... }`:
  derives the crate graph at eval time, then builds one CA derivation per
  compilation unit, wired by store paths the way godyn wires importcfg.
- **Graph resolution (decided 2026-09-13): import-from-derivation first.** A
  sandboxed derivation resolves the workspace (as godyn-gen does for Go) and
  its JSON output is imported at eval time. No Nix plugin, no coupling to the
  evaluator's Nix version, no network at eval. Keep the resolver behind a
  small interface (inputs: `Cargo.lock`, manifests, target description;
  output: a crate-graph JSON) so a **hybrid** stays possible: running an
  existing resolver, such as cargo-nix-plugin's, as a standalone tool inside
  that derivation, or loading it as a Nix plugin where hosts opt in.
- `buildRustAuto` (the `buildGoAuto` analog): rustdyn by default on every
  system igloo supports, with `buildRustPackage` kept as `passthru.brp` (the
  escape hatch), so consumers pin no strategy and key gates off
  `passthru.backend`.
- Parity knobs carried over from godyn where they make sense: `subPackages` →
  binary targets, `binaryNames`, `postInstall` + stdenv fixup, `tests = true`
  (per-crate `cargo test` equivalents: `passthru.tests`, `checkAll`), a clippy
  lane (`lintAll`), `testEnv`, `nativeCheckInputs`, `testFiles`.
- A producer protocol analog of RFC 0001 (flake-input crates), so a repo can
  depend on another fleet repo's crates through flake inputs instead of git
  dependencies plus `outputHashes`.

## Examples

Illustrative target shape, not an implemented interface:

    packages.default = pkgs.buildRustAuto {
      pname = "smith";
      src = self;
      version = "0.4.0";
      binaries = [ "smith" ];
      tests = true;
    };

    # edit crates/forgejo-api/src/lib.rs, then:
    nix build .#default   # rebuilds forgejo-api and its dependents only

## Limitations

Open questions to settle before `proposed`:

- **Unit of derivation.** A crate is not one rustc invocation: lib, bin, test,
  build script (compiled and *run*), and proc-macro (built for the host) are
  separate units, and one crate can be compiled with different feature sets for
  different dependents. Cargo's resolved unit graph
  (`cargo build --unit-graph`, unstable) versus reconstructing units from
  `cargo metadata` is the core design choice.
- **Build scripts.** `build.rs` runs arbitrary code, reads env and emits
  `cargo:rustc-link-*` / `cfg` directives. They must run hermetically per unit
  and feed their output into dependents, similar to godyn's cgo flag recording.
- **Native deps.** `cc`, `pkg-config` and `-sys` crates are the cgo analog
  (posh's mosh-ffi, piggy's PIV/pcsc stack).
- **Toolchain.** nixpkgs `rustc` versus rust-overlay pins (tap and tacky pin
  stable via rust-overlay today); editions and MSRV per crate.
- **Vendoring.** Registry crates as fixed-output fetches from `Cargo.lock`
  (as `importCargoLock` does), git dependencies, and which of that is the
  nix-authoritative manifest (the FDR 0008 question, for Cargo).
- **Crate types.** `cdylib`/`staticlib` (FFI into mosh), wasm targets (dodder's
  wasm filters), static builds (just-us `pkgsStatic`).
- **Tests.** Doctests, integration tests (`tests/`), and benches as separate
  units; test fixtures reading files outside the crate (godyn's `testFiles`).
- **Prior art to evaluate, not assume:**
  - **cargo-nix-plugin** (upstream `anthropics/cargo-nix-plugin`, which the
    README says Anthropic maintains; `numtide/cargo-nix-plugin` is a fork —
    numtide's go2nix is what godyn grew from; README read 2026-09-13): a
    **Nix plugin** (a shared
    library loaded via `plugin-files`) adding `builtins.resolveCargoWorkspace`.
    It resolves dependencies, features and `cfg()` for the target from
    `Cargo.lock` plus the sparse registry index (or pre-generated
    `cargo metadata`), then builds **one derivation per crate with nixpkgs
    `buildRustCrate`**. Also: git deps via `fetchGit`, a clippy lane that
    reuses dependency store paths, and per-member `runTests` (no doctests, no
    per-`[[bin]]` unit tests, no examples/benches). Trade-offs vs. this FDR:
    the plugin must match the evaluating Nix version exactly, must be loaded on
    every evaluating host, and fetches the index at eval by default; the README
    lists x86_64-linux, aarch64-linux and aarch64-darwin. Unverified: whether
    its derivations are content-addressed, and how one crate with differing
    feature sets per dependent is handled. It is the reference for the hybrid
    path above. Hybrid feasibility (read 2026-09-13): the resolver is its own
    crate, `cargo-nix-plugin-core`, built as `staticlib` + `rlib` with no
    `[[bin]]`; the C++ plugin links the staticlib. A thin wrapper binary over
    the `rlib` could run it inside a derivation (API unverified). It fetches the
    sparse index over HTTP, so in a sandbox only its explicit
    `cargo metadata` mode or a pre-warmed, hash-pinned index cache works.
  - nixpkgs `buildRustCrate` (per-crate; cargo-nix-plugin and crate2nix build
    on it), crate2nix's IFD mode, cargo2nix, and crane's deps/workspace split.
  - The POC should measure whether `buildRustCrate` fed by an IFD-resolved
    graph already gives per-crate builds with only the changed cone
    rebuilding, and whether those derivations can be content-addressed, before
    writing a new per-unit builder.
- Cross-system evaluation has godyn's import-from-derivation limit (igloo#75).

## Future Work

- **Nix evaluator plugins for rustdyn and godyn (flagged 2026-09-13).** We may
  later ship an optional plugin per builder that resolves the graph inside the
  evaluator: faster evaluation, and no cross-system IFD limit (igloo#75). IFD
  stays the default because plugins cannot be loaded by a flake or overlay
  (`plugin-files` is host config) and are bound to one Nix version. Keeping the
  resolver behind the graph-JSON interface above is what lets both the
  derivation and the plugin share one resolver.
- **Building Nix-version-bound plugins.** To ship such plugins, igloo may need a
  helper that builds a plugin against a pinned Nix (headers and ABI), emits one
  output per supported Nix version (as cargo-nix-plugin does with
  `cargo-nix-plugin-nix_2_31` etc.), and checks at eval that the loaded plugin
  matches the evaluator (an API-level handshake like cargo-nix-plugin's
  `apiLevel`). Fleet hosts would load it through their NixOS / nix-darwin /
  home-manager Nix settings (circus / eng), not through flakes.

## More Information

- Counterpart of: FDR 0007 (godyn-only Go builds), FDR 0008
  (nix-authoritative Go modules), RFC 0001 (flake-input-go_mod). FDR 0001
  (numtide go2nix) is the Go-side precedent for rejecting an evaluator plugin:
  no overlay or flake can load it (`plugin-files` is host config, outside the
  flake `nixConfig` allowlist) and its ABI is locked to one Nix version. godyn
  went to recursive-nix first, then to eval-time IFD graphs (FDR 0008), the
  route this FDR starts from.
- Prior art: https://github.com/anthropics/cargo-nix-plugin (fork:
  https://github.com/numtide/cargo-nix-plugin)
- Fleet inventory (2026-09-13, first-party `Cargo.toml` `[package]` entries,
  excluding vendored and POC trees; approximate): piggy 13, posh 6, just-us 5,
  langlang 5, smith 3, dodder 2, tap 1, tacky 1, hyphence 1, crap 1.
- Builders in use: `buildRustPackage` in posh, piggy, just-us, smith, tacky,
  crap and hyphence; crane in tap; rust-overlay toolchains in tap and tacky.
