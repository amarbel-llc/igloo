# rustdyn stage 3 — what must hold before posh opts in (design note, 2026-10-25)

Stage 3 of FDR 0009 is posh's opt-in: a `.#posh-native` output built by
rustdyn beside today's buildRustPackage output, its checks moved to
`checkAll` / `lintAll`, then the default. This note lists exactly what must
hold before that starts, after the cargo.nix reversal (decision c, 2026-10-25)
and with stage 2.5 landed. No code; posh's session does the posh side (igloo
does not edit posh). Labels: V observed in igloo, R read in a record, I
inferred.

## The reversal changes the opt-in shape

A cargo.nix workspace tracks no Cargo.toml or Cargo.lock (V: rustdyn refuses
them). posh's current default output is `buildRustPackage` over the tracked
files (R: FDR 0009 § 3). So "`.#posh-native` next to the default" cannot mean
"rustdyn next to an untouched buildRustPackage": the moment cargo.nix exists
the tracked files go, and the default must build from the rendered tree too.
The shape that fits:

    packages.posh        = buildRustAuto { …; manifest = ./cargo.nix; strategy = "brp"; };    # today's builder, rendered tree
    packages.posh-native = buildRustAuto { …; manifest = ./cargo.nix; strategy = "native"; }; # rustdyn

Both outputs come from one call's arguments (one cargo.nix, one version.env,
one `postInstall`), `passthru.brp` / `passthru.native` reach the other
backend from either, and the later "default = rustdyn" step is flipping
`strategy`. This is buildGoAuto's cut-over shape (R: godyn(7) buildGoAuto).

## Prerequisites, in order

1. **Migration tooling has run once on a real workspace (I → V).**
   `rustdyn-cargo -I .` on posh's checkout must produce a cargo.nix whose
   rendered Cargo.toml/Cargo.lock cargo accepts with `--locked`; the
   `manifest` fixture proves the round trip for a two-member workspace with
   no registry crates (V), not for posh's 39 lock entries, two git
   dependencies, a vendored path dependency and build scripts. First posh
   task: run `-I`, diff the rendered files against the tracked ones (they
   should differ only in TOML formatting), build with `strategy = "brp"`.
   Needs no network.
2. **Git dependencies before producers exist.** hyphence and rust-crap reach
   posh as cargo git dependencies today (R). cargo.nix's lock keeps them as
   git sources; `importCargoLock` needs `outputHashes` for them or
   `allowBuiltinFetchGit` — both are `buildRustAuto` arguments (V). So the
   opt-in does not wait for producers; `flakeInputs` replaces the git sources
   per crate when each producer publishes `packages.crates` (RFC 0002), and
   galapagos's vendored path dependency (`vendor/galapagos`, populated by
   posh's `postPatch` from the flake input, R) becomes the first `flakeInput`
   entry: it is already a flake input.
3. **Producers (RFC 0002) for the cut from git to flake inputs**:
   `mkRustCrates` in igloo (not written), then `packages.crates` on galapagos
   (`v2-rust`), hyphence (`rust/`) and rust-crap (`rust-crap/`). Needs the
   three repos' sessions; igloo's part is the helper and a fixture consumer.
4. **The escape hatch has run once (network).** `rustdyn-cargo -- cargo
   update` on the migrated posh is the first real `cargoRun`; it needs
   crates.io. Not before the coordinator clears a network fetch.
5. **Version and commit.** posh-build reads `POSH_VERSION` / `POSH_GIT_SHA`
   (R); rustdyn sets `POSH_VERSION` from version.env and `POSH_COMMIT` from
   the flake rev (V), so posh passes `memberEnv.POSH_GIT_SHA` or renames the
   variable in posh-build. One line either way; decide in posh.
6. **Install step.** scdoc manpages and completions in `postInstall` (R)
   move to buildRustAuto's `postInstall` + `nativeBuildInputs`, run once for
   both backends (V: the layered install derivation). The `symlinkJoin`
   toolset (R) stays a posh-side wrapper over the outputs.
7. **Tests.** posh runs `cargo test --workspace` in checkPhase, with e2e
   tests (R). Under rustdyn each member's lib harness and each `tests/*.rs`
   is a run derivation; tests that spawn posh's own binaries use
   `CARGO_BIN_EXE_*` (V: the `tests` fixture) and tests that need a PTY or
   the network are not runnable in the sandbox either way (same as today).
   Expect: `tests = true` on `posh-native`, `checkAll` wired as a check,
   `testEnv` for whatever the e2e tests read.
8. **Profiles.** posh's release profile sets thin LTO and strip (R); rustdyn
   builds at `-C opt-level=3 -C codegen-units=16` without LTO (V, rustdyn(7)
   LIMITATIONS). The brp output keeps the profile; the native output is
   larger and a little slower. Acceptable for the opt-in; a `profile`
   passthrough to buildRustCrate (`extraRustcOpts`) is the follow-up if size
   matters.
9. **The dev loop.** No ambient cargo (operator, 2026-10-25). posh's justfile
   recipes that call `cargo build/test/clippy` (R) need replacements: `nix
   build .#posh-native`, `.#posh-native.passthru.testWith`, `.#posh-native.passthru.lintAll`,
   and `rustdyn-cargo` for dependency changes. rust-analyzer: igloo#85's
   shape, not a stage 3 blocker but the first thing a posh developer will
   miss; say so in posh's README.
10. **Measurements** (FDR 0009 promotion criteria): cold, warm, leaf edit,
    test-file edit for `posh-native` against `posh` on a quiet host, with
    `just explore-cache-has-pkg` on the per-crate outputs once circus#385's
    roots exist. The stage 1 numbers (R) are the baseline to beat on the
    cutoff cases.

## What igloo owes before posh starts

- `mkRustCrates` (RFC 0002 producer helper) — only for step 3; steps 1–2 and
  4–10 need nothing new from igloo.
- A `profile` passthrough if step 8's size difference matters (follow-up).
- rustdyn(7) already documents everything the posh side needs to read (V).

## Not in stage 3

Cross targets, native dependencies (piggy, smith: stage 4), nextest, the
Zig/Rust registry (igloo#63), rust-analyzer.
