# rustdyn POC — per-crate content-addressed builds of posh

The stage-1 spike of FDR 0009 (`docs/features/0009-rustdyn-per-crate-rust-builds.md`),
run 2026-10-23 on one x86_64-linux host shared with seven other sessions
(load1 between 9 and 28 during the runs). A throwaway proof, not production
code: the question was whether godyn's shape (one content-addressed derivation
per unit, a graph derived at eval time) holds for cargo on a real fleet
workspace, and whether the leaf-edit loop beats the whole-workspace
`buildRustPackage` the fleet uses today.

## What was built

- **Resolver** (`poc.nix` → `graphDrv`): `cargo metadata --format-version 1
  --offline --locked` runs inside a derivation against the vendor directory
  `rustPlatform.importCargoLock` assembles from posh's `Cargo.lock` (git deps
  through `builtins.fetchGit`, as posh's own flake does). Its JSON is imported
  at eval time (import-from-derivation), plus a table of each vendored
  crate's real store path so a crate's derivation sources from that crate's
  fetch, not from the whole vendor directory.
- **Per-crate derivations**: a ~100-line mapper from the metadata (packages,
  targets, `resolve.nodes` with `dep_kinds`) to nixpkgs' `buildRustCrate`
  (decision a): lib target, build script, bins for workspace members only,
  unified features from the resolve node, normal vs build dependencies,
  `--extern` renames, `procMacro` for `serde_derive`, `codegenUnits = 16`
  (cargo's release default; buildRustCrate's own default of 1 made the first
  cold build 118.6 s) and `__contentAddressed = true` on every crate.
  Workspace members source from a filtered copy of their own directory, so
  an edit in one crate changes only that crate's source input. posh's build
  scripts get `POSH_VERSION` / `POSH_GIT_SHA` from the environment.
- **Baseline** (`brp`): `rustPlatform.buildRustPackage` on the same filtered
  tree, `doCheck = false` (tests are out of scope on both sides).
- **Harness**: `justfile` recipes (`setup`, `graph`, `build`, `smoke`, `cold`,
  `bench`, `repro`, `cache`) and `bench.sh`, each build behind the host
  guard the operator set (more than 4 GB available, load1 under 20; the
  harness waits for the host rather than aborting).

Posh at the master tarball of 2026-10-23 (5 workspace members: posh-build,
posh-term, posh-proto, poshterity, posh; galapagos vendored as a path
dependency; 37 packages in the resolve graph; registry crates plus two git
crates, hyphence and rust-crap; one proc-macro, serde_derive; build scripts in
four members and in libc, generic-array, proc-macro2, serde, serde_json).

## Results

Wall-clock through `nix build`, including evaluation and the resolver's
import-from-derivation; one host, loaded. "rebuilds" counts crate
derivations whose buildPhase ran (the resolver re-runs on every edit and is
not counted). Bench rows are the median of two runs (`just bench 2`);
single-run rows say so.

| scenario | per-crate (rustdyn) | buildRustPackage |
|---|---|---|
| cold, 37 crates | 70.4 s (37 rebuilds; 118.6 s at codegen-units=1) | 53.9 s (1 derivation; cargo `-j 8`, thin LTO from posh's release profile) |
| warm, no edit | 1.3 s (0; single run on a settled tree) | 1.1 s (0) |
| edit-leaf: semantic edit in posh-term/src/lib.rs | 36.4 s (4: posh-term, posh-proto, poshterity, posh) | 42.0 s (1) |
| comment-leaf: comment appended to posh-term/src/lib.rs | 24.0 s (4) | 42.0 s (1) |
| edit-test: comment appended to posh-term/tests/extensions.rs | 23.3 s median, 6.1 s best (1: posh-term only; dependents cut off) | 54.6 s (1) |
| edit-test, single clean run | 9.2 s (1; the three dependents cut off) | — |

The first bench pass (codegen-units=1, before the restore fix below) gave
edit-leaf 75.4 s and comment-leaf 50.1 s for the per-crate side, both with 4
rebuilds, against 36.8 s for the baseline: at one codegen unit the per-crate
side loses on every code edit. The second pass's "warm" rows for the
per-crate side were invalid (the harness's file restore changed the tree on
each early run) and are replaced by the single settled run above.

Other probes:

- **Smoke**: `posh version` and `poshterity --version` from the per-crate
  result print `0.0.0-rustdyn-poc+rustdyn-poc`, the version and sha the build
  scripts were handed through the environment.
- **Reproducibility**: the forced cold rebuild (every crate derivation
  changed by a throwaway `--cfg`) produced the same result store path as the
  first build, so all 37 content-addressed outputs were byte-identical across
  two independent builds; `just repro posh-term` (`nix build --rebuild`)
  re-ran the compile and reported no mismatch.
- **Early cutoff**: fires when the edited file is outside the compiled set
  (a `tests/*.rs` edit: posh-term rebuilt, its rlib identical, three
  dependents not rebuilt). It does **not** fire for a comment-only edit to a
  compiled file: the rlib changes. Theory, not verified: rustc records each
  source file's hash and length in the crate metadata, so any byte change in
  a compiled file changes the rlib. For the dependents' recompile this means
  the per-crate side only ever saves the crates outside the edited crate's
  dependent cone, never the cone itself; posh-term is the root of posh's
  cone (4 of 5 members), the worst case for a leaf edit.
- **Cache**: `nix copy` of one crate's output path to a `file://` cache
  wrote 1 NAR and 0 realisation records; copying an output path alone does
  not carry the derivation → output mapping a CA substitution needs. Whether
  the fleet cache can serve realisations (circus#219) is not answered here.

## Verdict

The shape holds. A stable `cargo metadata` run inside a derivation expresses
every unit posh needs; `buildRustCrate` carries the workspace (build scripts,
a proc-macro, git and path dependencies, version flow through the
environment) with no per-crate overrides; content-addressed outputs are
reproducible and the early cutoff works where the rlib is unchanged. None of
the spike's stop conditions fired: rustc output was reproducible, stable
cargo could express the units, and the leaf edit was not slower than the
baseline once codegen units matched (36.4 s against 42.0 s, within this
host's noise).

The wall-clock case is weaker than godyn's at posh's size and shape: the
per-crate cold build costs 1.3× the baseline, a code edit in the root crate
rebuilds 4 of 5 members and only roughly ties, and the clear wins are the
cutoff cases (a test-file or non-compiled edit, 9 s against 55 s) and the
structural ones the baseline cannot have at all: per-crate test and clippy
lanes, outputs shared across repos, and a graph that cannot drift. Stage 2
should be judged on those, measured on a quiet host, and on a consumer with a
flatter dependency shape than posh's.

## What the POC does not do (recorded, not fixed)

- A crate is one derivation (lib + bins + build script together), coarser
  than cargo's units; tests, doctests, examples and benches are not built.
- Dependency features are cargo metadata's unified set for the whole
  workspace; a dependency's target `cfg()` is not evaluated (every dependency
  edge is included; posh's lock has no non-Linux crates, so nothing broke).
- `buildRustCrate` ignores Cargo profiles: the per-crate build is
  `-C opt-level=3 -C codegen-units=16`, while the baseline honours posh's
  release profile (thin LTO, strip). The cold numbers are therefore not
  like-for-like on optimisation work.
- The resolver derivation depends on the whole filtered tree, so every edit
  re-runs `cargo metadata` (sub-second) and re-copies the tree; godyn's
  derived graph has the same property.
- `nix build --dry-run` lists every crate derivation as "will be built" even
  when their content-addressed outputs already exist; only the real build
  shows what ran. Count rebuilds from the build log, not from a dry run.
- `nixgc reap --with-referrers` could not delete the crate outputs on this
  host (every path reported a live referrer); the cold measurement uses the
  `coldToken` variant instead.
- The flake-input crate protocol, `buildRustAuto`, `postInstall`, clippy and
  test lanes are stage 2 and were not attempted.

## Reproduce

    just setup            # posh master tarball + its pinned galapagos, into ../../.tmp/rustdyn-poc
    just graph            # the resolver alone, prints the summary
    just build rustdyn    # per-crate build (or: build brp); prints elapsed
    just smoke
    just cold             # every crate derivation invalidated, timed
    just bench 2          # JSON; `just bench-md 2` for the table
    just repro posh-term
    just cache posh-term
