---
status: proposed
date: 2026-10-25
promotion-criteria: >-
  proposed → experimental: the spike in § Staged plan (stage 1) has run on
  posh and recorded the measurements it names here, with none of its stop
  conditions fired; then posh builds, tests and lints through rustdyn as an
  opt-in output (`.#posh-native`) from an igloo fixture-backed builder, with
  per-crate `tests`/`checkAll` and a clippy `lintAll`; the first consumer's
  measurements are recorded here.

  experimental → testing: posh's default output is rustdyn; a second
  consumer (piggy, with native deps) builds; fleet crates reach consumers as
  flake inputs rather than cargo git dependencies with `outputHashes`.
---

# rustdyn: per-crate content-addressed Rust builds

## Problem Statement

The fleet's Rust is built with `rustPlatform.buildRustPackage` (posh, piggy,
smith, just-us, tacky, crap's rust-crap, hyphence's test lane, mephisto,
prophit) or crane (tap). Both compile a whole Cargo workspace and its
dependencies in one or two derivations, so any source edit rebuilds and
re-tests everything, and nothing is shared between repos that depend on the
same crates. godyn solved exactly this for Go: one content-addressed
derivation per package, a package graph derived at eval time, cross-flake
composition through a producer protocol, and per-package test and lint lanes
(FDR 0007, FDR 0008). There is no Rust counterpart, and the fleet repeats the
per-repo toolchain, vendoring and flake-lock diamond problems (crane and
rust-overlay duplicated as `crane_2` / `rust-overlay_2` in cutting-garden,
dodder and moxy; shared `cargoLock.outputHashes` blocks in piggy; a vendored
path dependency populated by `postPatch` in posh) that godyn and
flake-input-go_mod removed on the Go side.

This record is the design note the operator asked for before any production
code (session igloo/slim-pecan, 2026-10-23). It answers five questions: what
of godyn's model transfers to cargo and what does not; what the existing
options do badly for us; which fleet repos would use rustdyn first and what
they need; a staged plan with a spike; and the decisions the operator has to
make. Everything below marked *recall* is from the author's general knowledge
and was not verified in this session; everything else was read from igloo's
code and man pages, the fleet's checkouts, or the cited upstream page.

## What godyn is, as read

The parts of godyn(7), FDR 0007, FDR 0008, FDR 0010 and
`pkgs/build-support/godyn/` that the transfer analysis below leans on:

- **One CA derivation per package.** `buildGodynModule` turns a graph into
  one `runCommandLocal` per package with `__contentAddressed = true`
  (`build-godyn-module.nix`, the `pkgDrvs` map). Each package's importcfg
  interpolates its dependencies' store paths (`packagefile <imp>=${dep}/pkg.a`),
  so nix records the edges as `inputDrvs`; `-trimpath` canonicalises the source
  path out of the archive so a byte-identical `pkg.a` keeps its store hash and
  dependents stay cached (early cutoff). The stdlib is one shared derivation
  built once with `go install std` and an importcfg of its own (`stdlib.nix`).
- **Graph derived at eval time.** `godyn-gen` (`go list -deps -json`) runs
  inside a derivation against the vendored module and its JSON is imported
  (import-from-derivation). Committing the graph is supported but not the
  recommended path (FDR 0008 § Decision: no committed graph); the cost is that
  evaluating another system's packages needs a builder for it (igloo#75).
- **go.nix manifest.** The module's dependencies live in a plain nix attrset
  (`require` with vendor hashes and each module's Go version, `flakeInputs`
  naming flake inputs for fleet modules, `replace`); igloo renders go.mod and
  gomod2nix.toml from it inside derivations and rejects a tracked go.mod. The
  rule is "no Go toolchain outside nix" (FDR 0008), which is what made go.mod
  removable from the checkout.
- **Escape hatch.** `passthru.goRun { command }` is an impure derivation
  (`__impure`, network on, never cached) that runs a go command against the
  rendered module and outputs a patch; `passthru.ingest` turns the resulting
  go.mod back into go.nix; `godyn-go` wraps both from a `git+file:` ref of the
  dirty tree. `godyn-test` runs one package's tests from the dirty tree
  (`passthru.testWith`), measured at ~2.5 s no-op on spinclass.
- **Tests.** Two CA derivations per tested package: the test binary (variant,
  external test package, captured testmain) and the run, whose pass/fail is
  the build result; `passthru.tests.<ip>`, `testBins`, `checkAll`. A `_test.go`
  edit re-runs exactly that package's tests because the normal archive sources
  only non-test files.
- **Vet and lint.** One CA derivation per package speaking the unitchecker
  protocol, facts chained along the same merkle-delta; `vetAll`, `lintAll`,
  `buildGodynLint`. Local packages' findings fail the build; third-party ones
  run facts-only.
- **Version embedding.** `-X main.version` from an explicit `version`, else
  `version.env`, else `"dev"`; `-X main.commit` from the flake input's rev;
  `passthru.version`, `passthru.ldflags`.
- **Cross-module composition.** `bridges` (compile the other module's packages
  in this graph from its go-pkgs source) and `archiveBridges` (link its
  pre-built archives); the two converge to the same CA archive under one
  toolchain, and source bridges are preferred because they need no toolchain
  lockstep.
- **Selector and install step.** `buildGoAuto` picks godyn or
  buildGoApplication (`passthru.native` / `passthru.bga` / `passthru.backend`);
  `postInstall` + `nativeBuildInputs` run as a separate install derivation
  layered on the CA link output, so editing the install script never re-links.
- **Measured shape (zz-pocs/godyn-v2).** Per-package CA wins for local edits at
  every module size (cone rebuild ~1 s flat against a whole-module rebuild
  that grows with the module) and loses for foundational edits where the cone
  is the whole module (per-derivation overhead). Locality, not size, is the
  determinant; that is why `buildGoAuto` exists.
- **FDR 0010** proposes replacing godyn's hand ports of cmd/go steps by
  replaying cmd/go's own plan (`go build -n`) per package. The Rust analog of
  that question is cargo's unit graph (below).

## Interface

Provisional, deliberately mirroring godyn so the two builders teach one
mental model. Every name is open until the spike has run.

- `buildRustdynWorkspace { pname, src, cargoLock ? "${src}/Cargo.lock",
  rustc ? pkgs.rustc, cargo ? pkgs.cargo, buildInputs, nativeBuildInputs,
  crateOverrides, version, pwd, commit, bins, binaryNames, postInstall,
  tests, testEnv, nativeCheckInputs, testFiles, clippyArgs, flakeInputs }`:
  derives the workspace's unit graph at eval time (import-from-derivation),
  then builds one CA derivation per unit, wired by store paths the way godyn
  wires importcfg (`--extern name=<store path>/lib<name>-<meta>.rlib`).
- `buildRustAuto` (the `buildGoAuto` analog): rustdyn on the systems igloo
  supports, `buildRustPackage` reachable as `passthru.brp`, `passthru.backend`
  recording the choice.
- Passthru surface, named as godyn's: `crates.<name>` (the per-crate lib
  derivations), `tests.<name>` / `testBins.<name>` / `checkAll`,
  `lint.<name>` / `lintAll` (clippy-driver), `version`, `graphFile` (the
  resolved graph the build used), `testWith { crate; testFlags; }` for the
  inner loop, and the install derivation as the result.
- Fleet crates arrive as flake inputs (`flakeInputs."<crate>" = { input;
  subPath; }`, the RFC 0001 analog), replacing cargo git dependencies plus
  `outputHashes`.

## Examples

Illustrative target shape, not an implemented interface:

    packages.default = pkgs.buildRustAuto {
      pname = "posh";
      src = self;                 # Cargo.toml + Cargo.lock at the root
      bins = [ "posh" "poshterity" ];
      tests = true;
      flakeInputs."galapagos" = { input = "galapagos"; subPath = "v2-rust"; };
    };

    # edit crates/posh-term/src/lib.rs, then:
    nix build .#posh   # rebuilds posh-term, posh, poshterity; not posh-proto, serde, ...

    # a comment-only edit in posh-term: posh-term recompiles, its rlib is
    # byte-identical, nothing above it rebuilds (the CA early cutoff)

## 1. What transfers from godyn, and what does not

| godyn piece | cargo counterpart | verdict |
|---|---|---|
| one CA derivation per package, deps interpolated into importcfg | one derivation per **unit**, deps as `--extern name=<store path>.rlib`; `--remap-path-prefix` for `-trimpath`; `-C metadata` derived from (name, version, features, deps' metadata, target) so symbol hashes are reproducible — nixpkgs' `buildRustCrate` already does all of this per crate (`build-crate.nix`) | transfers; whether a byte-identical rlib under `__contentAddressed` is reachable with rustc is the spike's first measurement |
| shared stdlib derivation | none needed: rustc ships a prebuilt sysroot (`-Zbuild-std` is out of scope) | simpler than godyn |
| graph derived at eval time by a tool run in a sandbox over the vendored module, imported as JSON | `cargo metadata --offline --locked` against an `importCargoLock` vendor directory (the same inputs `buildRustPackage` already sets up); JSON imported at eval | transfers, same IFD cost and cross-system limit (igloo#75) |
| derived graph is the *package* graph | cargo's build unit is finer than the crate: lib, each `[[bin]]`, the build script (compiled **and run**), proc-macros (host), test harnesses; and one crate can appear twice with different feature sets or on both host and target | does **not** transfer as-is: the resolver must emit units, not crates (§ Decisions, b) |
| go.nix: nix-rendered go.mod, no manifest in the checkout, "no toolchain outside nix" | Cargo.toml is also the compiler's input (edition, features, targets, lints, build-script declaration), and every fleet Rust repo's dev loop and its justfile run ambient `cargo` (posh, piggy, smith, just-us, tap, tacky); rust-analyzer needs Cargo.toml and Cargo.lock in the checkout | does **not** transfer wholesale. Cargo.toml and Cargo.lock stay authoritative; a nix manifest covers fleet crates only (§ Decisions, c) |
| vendor hashes recorded per module in go.nix | Cargo.lock already carries a checksum per registry crate; `importCargoLock` fetches each as its own fixed-output derivation with no hash to record; only git dependencies need `outputHashes` (or `allowBuiltinFetchGit`) | the lock is the manifest's hash table for free; git deps are what the flake-input protocol removes |
| escape hatch (`goRun` impure derivation, `ingest`, `godyn-go`) | `cargo update` / `cargo add` run with ambient cargo today and keep working; an impure `cargoRun` is mechanically identical (impure-derivations is enabled on the eng hosts) | transfers but is not needed while cargo stays supported outside nix; defer |
| per-package test binary + run derivations, `checkAll` | per-crate: the lib test harness (`--test` over `src/lib.rs`, one binary for all `#[test]`s in the crate), one binary per `tests/*.rs`, doctests via `rustdoc --test`; `CARGO_BIN_EXE_<name>` for integration tests that exec the crate's binaries (`buildRustCrate` does this) | transfers. Finer-than-package cutoff differs: Rust unit tests live in the same files as code, so a test edit recompiles the crate's lib too, but `cfg(test)` code is compiled out of the lib build, so the rlib stays byte-identical and dependents still early-cut |
| test-only tags, `testFiles`, `testEnv`, `nativeCheckInputs`, `testPreRun` | `[dev-dependencies]` and features play the tag role; integration tests reading fixtures outside the crate need the `testFiles` analog; `nativeCheckInputs` as in cargo-nix-plugin's `runTests` | transfers |
| vet lane (unitchecker facts chained per package) | no analog; rustc's own lints run in the compile | nothing to port |
| lint lane (`godyn-lint`, `lintAll`, `buildGodynLint`) | clippy-driver is a drop-in `rustc` that emits link-compatible rlibs, so a per-crate clippy lane reuses dependencies' store paths and re-lints only the edited cone (`buildRustCrate`'s `useClippy`; cargo-nix-plugin's `clippy` lane). `//nolint` becomes `#[allow]` / `[lints]`, which cargo already owns | transfers well |
| rustfmt | a per-file formatter: conformist's lane, not the builder's | out of scope |
| version embedding via `-X` ldflags | the fleet's convention is `build.rs` reading `version.env` or `<PKG>_VERSION` / `<PKG>_COMMIT` from the build environment (posh's `posh-build` crate, piggy, crap, tacky, smith's `BUILD_REV`); rustdyn sets those variables for every build-script run from `version.env` and the flake rev, and exposes `passthru.version` | transfers with the mechanism changed from linker flags to build-script env |
| `bridges` / `archiveBridges`, converging on one CA archive | flake-input crates compiled in this graph (source) or their rlibs linked (output); same convergence, same toolchain-lockstep caveat (rlibs are rustc-version-specific) | transfers; the fleet's cross-repo crate graph today is hyphence and rust-crap ← galapagos ← posh, prophit, mephisto, plus tap-dancer ← piggy, all as cargo git dependencies |
| `buildGoAuto` selector, `postInstall` install derivation, `binaryNames` | `buildRustAuto` with `passthru.brp`; the same install-step layering (posh and smith generate manpages and completions in `postInstall`) | transfers |
| `godyn-test` inner loop over `git+file:` | same wrapper shape over `passthru.testWith` | transfers; measured value depends on the eval floor (godyn: ~1 s copy + eval) |
| cgo: compile-kind from file lists, `#cgo` directives from the graph, `cc`, `buildInputs`, pkg-config at build time | `-sys` crates and build scripts: the build script probes `pkg-config` / `OPENSSL_DIR` at **run** time and emits `cargo:rustc-link-lib`, `cargo:rustc-cfg`, `cargo:rustc-env` and `DEP_<links>_*` metadata that dependents' build scripts read. nixpkgs' `defaultCrateOverrides` is the per-crate inputs table (openssl-sys, libgit2-sys, ...) and `buildRustCrate` propagates `links` metadata | partially transfers: harder than cgo because the probing is arbitrary code, but the prior art already carries it. Fleet exposure: smith (openssl, git2), piggy (openssl, pcsc); posh has none |
| build tags select files at graph time | **feature unification**: cargo picks each crate's feature set once per build from every dependent's requests, so the graph depends on which workspace members are built, and resolver 2 can give the same crate different features on host (build-dep) and target | does **not** transfer; it is the core resolver problem (§ Decisions, b) |
| Plan 9 asm | proc-macros: a crate compiled for the host as a dylib and loaded by rustc; `buildRustCrate` marks them `procMacro` and links them from the build platform | new unit kind, prior art covers it |
| one go.nix per module, go.work retired | a Cargo workspace is one lockfile and many members (posh 5, piggy 11 members + 2 excluded, smith 3); splitting it would fight cargo and the dev loop | the workspace stays the unit of resolution; members are the units of output |
| `graphFiles` per system, cross builds unvalidated (igloo#33) | rustc is a cross compiler (`--target`), but proc-macros and build scripts need the build platform; just-us already does `pkgsStatic` and `pkgsCross.aarch64-multiplatform.pkgsStatic` builds | out of scope for the spike; tracked like igloo#33 |
| `-race`, `cover`, `modes` | `-C instrument-coverage` (piggy's coverage variant), sanitizers | a per-unit `RUSTFLAGS` knob; `buildRustCrate` keeps instrumentation off proc-macros (`extraRustcOptsForProcMacro`) |

## 2. The existing options and what each does badly for us

Sources: the nixpkgs manual's Rust chapter and `buildRustCrate` source,
each project's README (read 2026-10-23), and how the fleet uses them.

| option | what it is | what it does badly for us |
|---|---|---|
| `buildRustPackage` + `importCargoLock` | the fleet default: one derivation runs `cargo build` and `cargo test` over the whole workspace against a vendor directory assembled from per-crate fixed-output fetches | no incremental anything: one edit rebuilds and re-tests every crate (piggy's `fibby` output re-vendors and rebuilds the workspace; posh's checkPhase re-runs every e2e test); git deps need `outputHashes` kept in lockstep across every derivation of the repo (piggy's `sharedCargoLock`) or `allowBuiltinFetchGit` (posh); nothing shared across repos; `useNextest`, features, `checkType` are whole-workspace knobs |
| crane | deps-only derivation (`buildDepsOnly`, a compressed `target/` tarball) then the workspace build on top; clippy, fmt, doc, nextest, llvm-cov lanes | two coarse derivations, never per crate; the artifact cache is a `target/` blob, not store paths other repos can share; it pulls its own inputs and the fleet pins it with rust-overlay, which is the `crane_2` / `rust-overlay_2` diamond cutting-garden, dodder and moxy comment about; tap is the only user |
| naersk | the same two-step split, parsing Cargo.lock in nix (no IFD) | same coarseness; ignores `rust-toolchain`; `overrideAttrs` footgun documented in its README; no fleet user |
| cargo2nix | `cargo2nix` generates a committed `Cargo.nix`; an overlay with `makePackageSet` builds each crate by driving `cargo` in isolation, propagating linker flags through outputs | a committed generated file that drifts (what FDR 0008 removed for Go), its own overlay and rust-overlay dependency, builds "as if every workspace member might be built" (feature over-approximation by design), per-crate but not content-addressed |
| crate2nix | reads Cargo.toml and Cargo.lock via `cargo metadata`, renders `Cargo.nix` (one `buildRustCrate` per crate) through templates; has an IFD mode (`tools.generatedCargoNix`) and an experimental pre-resolved JSON mode (`crate2nix generate --format json` + `lib/build-from-json.nix`) | the closest prior art and in nixpkgs (0.15.0 here). Costs: generated nix (committed, or IFD of a template render), `buildRustCrate`'s test limits (below), input-addressed derivations by default, no fleet protocol, no version embedding, no install-step layering |
| cargo-nix-plugin (anthropics; numtide fork) | a Nix **plugin** adding `builtins.resolveCargoWorkspace`; resolves features and `cfg()` from Cargo.lock plus the sparse registry index (or `cargo metadata` JSON) and builds each crate with `buildRustCrate`; clippy lane sharing dependency store paths; `runTests`, `doctest`, `verify`; x86_64-linux, aarch64-linux, aarch64-darwin | the plugin must match the evaluating Nix version exactly and be loaded from host config, which no flake or overlay can do (the FDR 0001 objection); default mode fetches the index at eval; git deps via eval-time `fetchGit`. Its resolver core is a separate crate (`cargo-nix-plugin-core`, FDR 0009 earlier reading) that could run **inside a derivation** instead, which is the hybrid this record keeps open |
| nixpkgs `buildRustCrate` | the per-crate `rustc` driver every per-crate tool above builds on: `--extern` wiring, `-C metadata` hashing, build-script run with `links` propagation, proc-macro handling, `buildTests` with `tests/*.rs` and `CARGO_BIN_EXE_*`, `useClippy`, `[lints]` translation, `--remap-path-prefix` | a crate is one derivation (lib + bins + build script together), coarser than cargo's units; tests are a second derivation of the same crate; no doctests, no per-`[[bin]]` unit tests; input-addressed, though unrecognised attributes pass through to `mkDerivation`, so `__contentAddressed = true` may simply work (unverified) |
| dynamic derivations / recursive-nix | Nix experimental features (both enabled on the eng hosts) that let a build emit `.drv` files or nested builds | godyn's own history: the recursive-nix resolver re-ran on every edit and lost 2x to the eval-time graph (zz-pocs/godyn-v2); dynamic derivations would remove the IFD cross-system limit but have no known cache or CA story and godyn deliberately avoids them. Keep as a later option, not a foundation |

**Why have our own.** None of the above gives, in one place: content-addressed
per-unit derivations with early cutoff; a graph that cannot drift because it
is derived from the lock at eval time, with no committed generated file and no
Nix plugin; a fleet protocol for cross-repo crates through flake inputs; the
fleet's version embedding and install-step conventions; and a passthru
surface (`checkAll`, `lintAll`, `testWith`) that the Go side already taught
every consumer. rustdyn is the thin layer that adds those; what it should
**not** re-implement is the per-crate `rustc` driver, where `buildRustCrate`
is mature and already feeds two of the tools above.

## 3. First consumers and what they need

Rust in the fleet (first-party `Cargo.toml`, read 2026-10-23; vendored and
POC trees excluded):

| repo | crates | lock entries | builder today | native deps | version / manpages | cross-repo crates |
|---|---|---|---|---|---|---|
| posh | 5 members (posh, posh-term, posh-proto, poshterity, posh-build) + galapagos as a vendored path dep | 39 | `buildRustPackage`, `allowBuiltinFetchGit`, `postPatch` copies the galapagos flake input into `vendor/`; `cargo test --workspace` in checkPhase | none (libc, aes-gcm, serde_json) | `version.env` via `posh-build` build.rs with `POSH_VERSION` / `POSH_GIT_SHA` env; scdoc manpages and completions in `postInstall`; `symlinkJoin` toolset | consumes galapagos (flake input), hyphence and rust-crap (git deps through galapagos and directly) |
| piggy | 11 members, 2 excluded (pigpen with its own lock, askpass-gtk) | 275 | `buildRustPackage` ×3 (piggy-rs, piggy-rs-cov, fibby) over one `sharedCargoLock` with `outputHashes` for tap-dancer; wrapper derivation bakes `PIGGY_VERSION` / `PIGGY_COMMIT`; VM test lanes; `-C instrument-coverage` variant | openssl, pcsclite (linux), gtk4 (askpass) | build.rs reads `version.env`; scdoc manpages in the wrapper | consumes tap-dancer (git dep) |
| smith | root bin + 2 members (cutting_garden, forgejo-api fork) | 320 | `buildRustPackage`, `cleanSource`; `BUILD_REV` env; separate `packages.doc` so a manpage edit does not relink | openssl, git2 | `version.env` mirrors `Cargo.toml` version; clap_mangen pages generated by running the binary; completions | none |
| just-us | fork of just + 4 helper crates | 187 | `buildRustPackage`, plus `pkgsStatic` and `pkgsCross.aarch64-multiplatform.pkgsStatic` static builds | none | upstream's build.rs | none |
| tap (`rust/`) | 1 (tap-dancer) | 38 | crane + rust-overlay stable | none | `version.env` | consumed by piggy as a git dep |
| tacky | 1 | 39 | `buildRustPackage` under rust-overlay stable; darwin-only (objc2 / AppKit) | AppKit frameworks | `TACKY_COMMIT` env | none |
| hyphence (`rust/`) | 1 library | 1 | `buildRustPackage` test lane | none | — | consumed by galapagos, posh, prophit, mephisto as a git dep (tag v0.1.0) |
| crap (`rust-crap/`) | 1 library | 12 | `buildRustPackage` | none | `CRAP_VERSION` env guarded by build.rs | consumed by galapagos, posh, prophit, mephisto as a git dep |
| galapagos (`v2-rust/`) | 1 library + elevator | 23 | justfile-driven cargo; consumed as source | none | — | consumes hyphence, rust-crap; consumed by posh (flake input), prophit, mephisto |
| mephisto, prophit | 2 + trader, 1 | 135, 138 | `buildRustPackage` (trader) | none | — | consume galapagos, hyphence, rust-crap |
| langlang (`rust/`), dodder (`rust/abscess`) | 5, 1 | 36, 200 | not nix-built from these trees as far as the flakes show | — | — | — |

What they need from rustdyn, in the operator's list:

- **Toolchain pinning.** Most repos take `rustc` and `cargo` from igloo's
  nixpkgs (1.98.1 on this host); tap and tacky pin `rust-bin.stable.latest`
  through rust-overlay, which is where the lock diamonds come from. rustdyn
  takes `rustc` / `cargo` arguments defaulting to igloo's nixpkgs toolchain, so
  a consumer on rust-overlay keeps its pin without igloo growing a registry
  (there is no `go-toolchain`-style need yet: nobody waits on a point release).
- **nextest.** No fleet Rust repo uses it (grep of every justfile and flake).
  Its value, per-test process isolation and partitioning, is mostly what
  per-crate test derivations give for free; not in the spike.
- **clippy.** piggy, smith, tacky and the conformist templates gate on
  `cargo clippy -- -D warnings` through conformist's impure clippy linter.
  rustdyn's `lintAll` is the pure, per-crate, cached version of that gate;
  the impure lane stays the dev loop, as godyn-lint and golangci-lint did.
- **rustfmt.** conformist's formatter; nothing for rustdyn.
- **Version embedding.** Every consumer flows `version.env` and a rev through
  build.rs env. rustdyn sets `<PNAME>_VERSION` and `<PNAME>_COMMIT` (and the
  generic `RUSTDYN_VERSION` / `RUSTDYN_COMMIT`) in each build-script run and
  exposes `passthru.version`, so consumers drop the per-flake `builtins.match`
  over version.env.
- **Manpages.** scdoc pages and binary-generated pages land in `postInstall`
  (posh, piggy) or a sibling derivation (smith's `packages.doc`, the better
  shape: a docs edit never relinks). godyn's layered install derivation gives
  both: `postInstall` runs over the CA link output in its own derivation.

## 4. Staged plan

**Stage 0: reading (this record).** Done 2026-10-23.

**Stage 1: the spike, on posh.** posh is the right first crate: a real
multi-member workspace (5 crates, a lib ← bin chain, build scripts in four of
them), a small registry set (39 lock entries, two proc-macro crates via
serde_derive), git and flake-input dependencies (hyphence, rust-crap,
galapagos), no native libraries, Linux-buildable, and its tests already run
in the sandbox. hyphence's one-crate library is the fallback smoke fixture if
posh's git deps get in the way. The spike lives under `zz-pocs/rustdyn-poc/`
in igloo with posh as a `flake = false` input (read-only; no edits to posh),
like the godyn POCs.

Steps, each its own `just explore-*` recipe:

1. **Resolver derivation.** Run `cargo metadata --format-version 1 --offline
   --locked` inside a derivation whose vendor directory comes from
   `importCargoLock` (with `allowBuiltinFetchGit` for posh's git deps); emit a
   unit-graph JSON (crate, version, source, kind, features, host/target,
   dependency edges by unit). Import it at eval. This is the godyn-gen analog.
2. **Per-unit derivations.** Feed the graph to `buildRustCrate` with
   `__contentAddressed = true; outputHashMode = "recursive";` passed through,
   one derivation per crate (its coarsest unit), the nixpkgs `rustc`.
   Record whether CA is accepted and whether two builds of the same inputs
   produce the same output hash.
3. **Measurements**, each against `buildRustPackage` on the same posh rev
   and the same host, three runs, median:
   - cold build wall time and derivation count;
   - no-op rebuild (eval floor);
   - a one-file semantic edit in `posh-term` (the leaf most of the workspace
     depends on): wall time and the number of derivations rebuilt (expected:
     posh-term, posh, poshterity; not posh-proto, not registry crates);
   - a comment-only edit in `posh-term`: whether dependents rebuild (the CA
     early-cutoff proof; expected: one derivation rebuilt);
   - cache behaviour: after a build, `nix path-info` on the per-crate outputs
     and whether a second checkout of the same rev substitutes them (the
     circus#219 question, realisations for CA outputs).
4. **Tests.** `buildTests = true` for `posh-term` and `posh`: do the lib tests
   and `tests/*.rs` compile and pass per crate; does a test edit leave the
   lib rlib byte-identical.
5. **Clippy.** `useClippy = true` on one workspace member against the shared
   dependency outputs; confirm dependency store paths are reused.

Stop conditions, any one of which ends the spike with a written reason:

- rustc output is not stable across identical inputs (two builds, two
  hashes) and no flag set makes it so: without early cutoff rustdyn is
  cargo2nix with extra steps.
- `cargo metadata` (stable) cannot express the units posh needs and the only
  route is a nightly cargo (`--unit-graph` is nightly-only, *recall*).
- the semantic one-file edit is not faster than `buildRustPackage` on posh,
  which is exactly where godyn-v2 found bga winning for foundational edits;
  if a leaf edit in a 5-crate workspace does not win, the shape is wrong for
  the fleet's sizes.
- a single `nix build` of the spike needs more than the host can give (the
  operator's rule: one build at a time, more than 4 GB available first).
- `buildRustCrate` cannot carry posh's build scripts and the estimate for an
  own per-unit driver exceeds what a first consumer justifies; that is a
  decision point, not a silent pivot.

**Stage 1 results (2026-10-23, `zz-pocs/rustdyn-poc/README.md`).** The spike
ran on posh (37 crates, 5 members) on one loaded shared host. The resolver
(`cargo metadata --offline --locked` in a derivation, imported at eval) and a
~100-line metadata → `buildRustCrate` mapper built the workspace with
`__contentAddressed` on every crate; the binaries run and report the version
the build scripts were handed. Cold: 70.4 s for 37 crate derivations against
53.9 s for `buildRustPackage` (118.6 s before matching cargo's 16 codegen
units). Warm floor 1.3 s against 1.1 s. A semantic edit in posh-term, the
root of the cone, rebuilt 4 of 5 members in 36.4 s against 42.0 s. A
comment-only edit also rebuilt 4: the rlib changes on any byte change to a
compiled file (theory: rustc records source hashes in the crate metadata), so
the cutoff never saves the edited crate's own dependent cone. An edit to a
`tests/*.rs` file rebuilt posh-term alone in 9.2 s and cut off its three
dependents, against 54.6 s. Reproducibility held: a forced rebuild of every
crate gave the identical result path, and `nix build --rebuild` of posh-term
reported no mismatch. `nix copy` of an output path wrote no realisation
record (the cache question, circus#219, is open). No stop condition fired.
Verdict: the shape holds, the wall-clock case at posh's size rests on the
cutoff cases and on the structural gains (per-crate test and lint lanes,
cross-repo sharing, a non-drifting graph) rather than on code edits in the
cone root; stage 2 is worth doing and should be measured on a quiet host.

**Stage 2: builder and fixtures in igloo.** `pkgs/build-support/rustdyn/`
with a `rustdyn(7)` manpage; fixtures under `tests/` mirroring godyn's
(`multi`, `tests`, `lint`, `postinstall`, `flakeinput`); `buildRustAuto`;
`tests = true`, `lintAll`, `postInstall`, version env; flake checks named
`rustdyn-*` beside the `godyn-*` ones.

**Stage 2 results (2026-10-25, approved by the operator the same day).**
`buildRustdynWorkspace`, `buildRustAuto` and `rustdynSystems` landed in
`pkgs/build-support/rustdyn/` with `rustdyn(7)`; eight `rustdyn-*` checks
build on x86_64-linux (`just test-rustdyn`, V): `multi` (two members, a path
dependency, a build script reading the version env), `tests` (per-harness run
derivations: lib harness, two integration tests of which one execs the bin
through `CARGO_BIN_EXE_*` and one reads a fixture through the run-time
`CARGO_MANIFEST_DIR`, the bin's unit harness; `checkAll`), `tests-fail` (a
failing test fails its run, exit 101), `lint` (clippy-driver standing in for
rustc on the members only; the clean member passes `-D warnings`, the bad one
fails on `clippy::bool_comparison`), `postinstall` (rename + postInstall with
a native input, crate derivations unchanged), `auto` (both backends print the
same), and the manpage. Not in stage 2 after all: the `flakeinput` fixture
(stage 3 defines the protocol first). Two findings for the cache question:
vendored crates source from a small content-addressed copy derivation of the
vendor dir's entry, because `builtins.storePath` (the spike's route) is
unavailable in pure evaluation, so a lock change leaves the compile
derivations' resolved inputs unchanged; and a CA derivation's realisations
exist only for the outputs something linked (a lib crate's unused `out` has
none after a successful build, V), so a cache probe must ask per wanted
output (`just explore-cache-has-pkg`). The fleet cache held none of the
fixtures' outputs when probed (consistent with the godyn finding of the same
day: the uploader on flic is selective or rare; circus's lane). Measurements
against `buildRustPackage` on posh wait for a quiet host (the spike's
harness, § Stage 1 results, is the like-for-like run).

**Stage 2.5: the cargo.nix manifest (decided 2026-10-25).** The go.nix
half for Rust: `cargo.nix` at the workspace root holds the workspace and
member manifests as Nix attribute sets (the TOML tables, one to one), the
lock as data, and `flakeInputs` for fleet crates; rustdyn renders
Cargo.toml per member and Cargo.lock into the tree it hands the resolver,
rejects a tracked Cargo.toml or Cargo.lock, ingests a rendered pair back
into cargo.nix (`builtins.fromTOML`), and offers the escape hatch
(`cargoRun`, `ingest`, a `rustdyn-cargo` CLI) for `cargo add`/`update`.
Fixtures mirror stage 2's on cargo.nix; checks `rustdyn-manifest-*`.
RFC 0002 specifies the flake-input half.

*Stage 2.5 results (2026-10-25, same evening):* `rustdynManifest`
(normalize, resolve, render, ingestRendered, withCargoManifest) landed;
`manifest = ./cargo.nix` on `buildRustdynWorkspace` and `buildRustAuto`
renders the tree for both backends. The `manifest` fixture (the `multi`
workspace with no tracked Cargo.toml or Cargo.lock, versions from
version.env) builds on both backends and prints the version (V); the
rendered tree reads back equal to the normalized manifest, workspace,
members and lock (V); a cargo.nix beside a tracked Cargo.toml is refused at
evaluation (V). Not yet: the escape hatch (`cargoRun`, `rustdyn-cargo`,
ingest of a produced Cargo.lock), so a registry crate's lock entry still
comes from a Cargo.lock cargo produced elsewhere, and no fixture has a
registry dependency yet (the first needs one network fetch).

**Stage 3: posh opt-in, then default.** `.#posh-native` next to the
buildRustPackage output, its checks moved to `checkAll` / `lintAll`; the
flake-input crate protocol (an RFC, sibling to RFC 0001) so galapagos,
hyphence and rust-crap reach posh, prophit and mephisto without git deps or
`outputHashes`; then `packages.default`.

**Stage 4: native deps and the rest.** piggy (openssl, pcsc, the coverage
variant, the wrapper), smith (git2, generated manpages), tap and tacky off
rust-overlay if they choose; `rustdyn-test` inner loop.

## 5. Decisions (decided 2026-10-23)

Each was put to the operator with the recommendation this reading supports;
the operator accepted all nine as recommended (relayed by
circus/eager-holly/clarabell, 2026-10-23), and the record moved from
`exploring` to `proposed` on that ruling. The spike in § Staged plan runs
under these decisions; the "Recommend:" wording below is kept so the
reasoning stays legible.

- **(a) Reuse `buildRustCrate` or write a per-unit driver?** Recommend:
  reuse `buildRustCrate` for the spike and stage 2. It already owns the parts
  that cost godyn the most (build scripts with `links` propagation,
  proc-macros, `--extern` wiring, reproducible `-C metadata`, tests with
  `CARGO_BIN_EXE_*`, clippy-driver). Write our own driver only if the spike
  shows CA cannot be reached through it or its crate-level granularity costs
  measurable rebuilds.
- **(b) Resolver: `cargo metadata` (stable, offline), cargo's `--unit-graph`
  (nightly, *recall*), or cargo-nix-plugin's core run as a tool inside the
  derivation?** Recommend: `cargo metadata` first; its `resolve` section
  carries unified features and dependency kinds per package. Accept that
  resolver-2's host/target feature split is approximated (the same
  approximation crate2nix and cargo2nix live with) and record it as a known
  gap. Keep the graph JSON as the interface so the resolver can be swapped,
  as FDR 0010 argues for godyn.
- **(c) A nix-authoritative manifest (a `cargo.nix`) or Cargo.toml plus a
  committed Cargo.lock?** Recommend: Cargo.toml and Cargo.lock stay
  authoritative and in the checkout; cargo outside nix stays supported for
  Rust. The FDR 0008 move only paid off because the Go toolchain was banned
  outside nix; the fleet's Rust dev loop (justfiles, rust-analyzer, clippy
  lane) runs ambient cargo in every repo. A nix manifest is limited to
  `flakeInputs` for fleet crates, which is the one thing Cargo.lock cannot
  express without a git dependency.

  **Reversed by the operator on 2026-10-25** (after stage 2 landed on a
  tracked Cargo.toml/Cargo.lock): a `cargo.nix` per workspace root is the
  manifest, Cargo.toml and Cargo.lock are rendered from it at evaluation
  time and tracked by no repository, `cargo add`/`update` run through an
  escape hatch that writes cargo.nix back, and ambient cargo leaves the dev
  loop as the Go toolchain did under FDR 0008 (rust-analyzer over a
  rendered tree is a later POC, igloo#85's shape). This is stage 2.5 below;
  the design note is `docs/plans/2026-10-25-rustdyn-stage25-cargo-nix.md`.
  The stage 2 builder keeps accepting a tracked manifest until the
  consumers have cut over.
- **(d) Toolchain source.** Recommend: igloo's nixpkgs `rustc` / `cargo` by
  default, overridable per consumer; no registry until a consumer needs a
  release nixpkgs lacks. tap and tacky keep rust-overlay if they want it.
- **(e) Graph mechanism: IFD, dynamic derivations, or a Nix plugin.**
  Recommend: IFD, as godyn (FDR 0008 § Decision). Dynamic derivations are
  enabled on the eng hosts but experimental with no known binary-cache story;
  a plugin is bound to one Nix version and cannot be loaded by a flake
  (FDR 0001). Both stay in Future Work.
- **(f) First consumer.** Recommend: posh (reasons in stage 1); hyphence's
  crate as the smoke fixture.
- **(g) Dev loop.** Recommend: ambient cargo stays; `rustdyn-test` (the
  `godyn-test` analog) comes in stage 4 if the inner loop's eval floor makes
  it worth having.
- **(h) Test granularity.** Recommend: per crate, the lib harness and each
  `tests/*.rs` as separate run derivations, doctests as their own lane
  later; no nextest.
- **(i) Where and what name.** Recommend: `pkgs/build-support/rustdyn/`,
  `buildRustdynWorkspace` and `buildRustAuto`, `rustdyn(7)`; checks
  `rustdyn-*`.

## What rustdyn must expose for dagnabit (not designed here)

dagnabit's rust mode (purse-first FDR 0011) computes crate heights from
`cargo metadata --no-deps` path dependencies between workspace members and
repositions crates into NATO-level directories (dagnabit(7) § THE LEVEL
RULE). A later purse-first session explores dagnabit as a layout lint over
rustdyn; rustdyn should expose, as data, not behaviour:

- the resolved graph the build used (`passthru.graphFile`, the JSON from
  step 1), with the workspace members distinguished from registry, git and
  flake-input crates, and each member's dependency edges by kind (normal,
  build, dev) and by target;
- the member list and each member's directory relative to `src`, so a level
  can be read off the path and compared with the computed height;
- per-member derivations (`passthru.crates.<name>`), so a lint lane can hang
  off the same store paths without re-resolving.

Heights and levels stay dagnabit's computation; rustdyn provides the edges.
A shared JSON shape with godyn's graph (nodes with `dir`, `local`, `imports`)
would let one dagnabit reader serve both and is worth settling when that
session starts.

## Limitations

- Everything above is design; nothing is built. The spike's measurements
  decide whether the shape holds for a 5-crate workspace.
- Cross-system evaluation keeps godyn's IFD limit (igloo#75); darwin and
  aarch64 are unvalidated as for godyn (igloo#33).
- Feature resolution precision under resolver 2 is approximated by the
  `cargo metadata` route (decision b).
- `buildRustCrate` has no doctests and no per-`[[bin]]` unit tests; the
  former is a later lane, the latter an accepted gap unless a consumer hits
  it.
- Build scripts that shell out to `git` (posh-build, piggy, smith) find no
  repository in the sandbox and fall back as they do under `buildRustPackage`
  today; rustdyn supplies the rev through the environment instead.

## Future Work

- **Nix evaluator plugins for rustdyn and godyn (flagged 2026-09-13).** An
  optional plugin per builder resolving the graph inside the evaluator: faster
  evaluation, no cross-system IFD limit. IFD stays the default because
  plugins cannot be loaded by a flake or overlay and are bound to one Nix
  version. Keeping the graph JSON as the interface lets both share one
  resolver; cargo-nix-plugin's `cargo-nix-plugin-core` is a candidate to run
  inside the resolver derivation.
- **Building Nix-version-bound plugins.** A helper that builds a plugin
  against a pinned Nix, one output per supported version, with an eval-time
  API-level handshake, loaded through host Nix settings (circus / eng).
- **Dynamic derivations** as the graph mechanism once they have a cache story.
- **Flake-input crates RFC**, the RFC 0001 sibling, once stage 3 starts.

## More Information

- Counterpart of: FDR 0007 (godyn-only Go builds), FDR 0008
  (nix-authoritative Go modules), FDR 0010 (replaying cmd/go's plan), RFC 0001
  (flake-input-go_mod). FDR 0001 (numtide go2nix) is the Go-side precedent for
  rejecting an evaluator plugin.
- Prior art read 2026-10-23: the nixpkgs manual's Rust chapter and
  `pkgs/build-support/rust/build-rust-crate/` (nixpkgs on this host);
  https://github.com/ipetkov/crane; https://github.com/cargo2nix/cargo2nix;
  https://github.com/nix-community/crate2nix; https://github.com/nix-community/naersk;
  https://github.com/anthropics/cargo-nix-plugin (fork:
  https://github.com/numtide/cargo-nix-plugin); the Nix manual's
  experimental-features page (`ca-derivations`, `dynamic-derivations`).
- dagnabit(7) and purse-first FDR 0011 (dagnabit rust mode) for the layout
  lint's inputs.
- zz-pocs/godyn-v2/README.md for the locality-not-size measurement that
  motivates `buildRustAuto`.
