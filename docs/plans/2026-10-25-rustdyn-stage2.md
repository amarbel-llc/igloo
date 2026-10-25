# rustdyn stage 2 — builder and fixtures in igloo (plan, 2026-10-25)

FDR 0009 § Staged plan, stage 2, approved by the operator 2026-10-25 (relayed
by circus/eager-holly). Written by session igloo/slim-pecan before any code.
Labels as in the triage note: **V** observed, **R** read, **I** inferred.

## Scope

In: `pkgs/build-support/rustdyn/` with `buildRustdynWorkspace`,
`buildRustAuto`, `rustdynSystems`, `rustdyn(7)`; fixtures under `tests/`
(`multi`, `tests`, `lint`, `postinstall`); `tests = true` with per-harness run
derivations and `checkAll`; a clippy `lintAll`; the layered install derivation
with `postInstall`; version flow through build-script environment; flake
checks `rustdyn-*` beside `godyn-*`; the cache check as a read-only recipe
over the fixtures' CA outputs.

Out (stage 3 or later, per the FDR): the flake-input crate protocol and its
`flakeinput` fixture (the RFC defines it first), `rustdyn-test`, native-deps
overrides beyond what `defaultCrateOverrides` already carries, doctests,
posh's opt-in output.

## Design, from the reads

- **Resolver** (`cargo metadata --format-version 1 --offline --locked` in a
  derivation over `rustPlatform.importCargoLock`'s vendor dir), imported at
  eval; the spike's shape (`zz-pocs/rustdyn-poc/poc.nix`, V). `passthru.graphFile`
  is the metadata JSON (what dagnabit asked for, FDR 0009 § dagnabit).
- **Per-crate derivations** through `buildRustCrate` (decision a), every one
  `__contentAddressed`. Members source from a filtered copy of their own
  directory under `src`; vendored crates source from a small CA copy
  derivation of the vendor dir's `<name>-<version>` entry, so a lock change
  changes the copy derivation but not its output, and the compile derivation
  resolves to the same inputs (the CA early cutoff carries cross-repo sharing;
  the spike's `builtins.storePath` route is impure and unavailable in a flake,
  V: `builtins.storePath` is refused in pure evaluation, R from the Nix manual).
- **Tests** (decision h): one `buildTests = true` derivation per member (the
  lib harness, each `tests/*.rs`, the member's bins for `CARGO_BIN_EXE_*`,
  all in `$out/tests` and `$out/bin`, V: install-crate.nix), then one CA run
  derivation per harness binary with `testEnv`, `nativeCheckInputs`, cwd the
  member's source dir and `CARGO_MANIFEST_DIR` set. `passthru.tests.<member>.<harness>`,
  `testBins.<member>`, `checkAll`, `testWith { crate; harness; testFlags; }`.
- **Lint**: clippy-driver in rustc's place. A shim package whose `bin/rustc`
  is `clippy-driver` is handed to `buildRustCrate` as `rust` for member crates
  only, with `capLints = "forbid"` (the default `allow` cap silences
  everything, V: default.nix resolvedCapLints) and `-D warnings` plus
  `clippyArgs`; dependencies are the normal rlibs, so an edit re-lints only
  its cone. nixpkgs' clippy is built against the same rustc source (V:
  clippy.nix), and clippy-driver locates the sysroot itself (I: to verify
  with the fixture; the fallback is `SYSROOT=${rustc}` in the shim).
- **Install derivation**: `stdenv.mkDerivation` with no source; copies member
  bins (optionally renamed through `binaryNames`), runs `postInstall` with
  `nativeBuildInputs`, then stdenv's fixup, as godyn does.
- **Version**: explicit `version` > `version.env` in the workspace dir > `"dev"`
  (godyn's rule, V: build-godyn-module.nix); `commit` from `src.rev` /
  `shortRev` else `"unknown"`. Every member build gets `RUSTDYN_VERSION`,
  `RUSTDYN_COMMIT`, `<PNAME>_VERSION`, `<PNAME>_COMMIT` and any `memberEnv`
  attrs (posh reads `POSH_GIT_SHA`, R: FDR 0009 § 3).
- **buildRustAuto**: `strategy ? null` → rustdyn on `rustdynSystems`, else
  `buildRustPackage`; `passthru.native` / `passthru.brp` / `passthru.backend`.

## Test-first order (red observed before each green)

1. Fixture `multi` (workspace: `greet` lib, `app` bin with a build.rs that
   reads the version env) + flake package/check `rustdyn-multi-test` asserting
   the binary's output. Red: attribute missing. Green: builder core.
2. `tests` fixture (unit test, `tests/*.rs`, one exec'ing the bin through
   `CARGO_BIN_EXE_app`) → `rustdyn-tests-test` on `checkAll`; `tests-fail`
   fixture → `rustdyn-tests-fail-test` with `testBuildFailure'`.
3. `lint` fixture (`ok` clean, `bad` with a clippy finding) →
   `rustdyn-lint-test` on `ok`'s lint, `rustdyn-lint-fail-test` on `bad`'s.
4. `postinstall`: `rustdyn-postinstall-test` (marker file, rename).
5. `rustdyn-auto-test`: both backends run the `multi` binary.
6. `rustdyn-man`: scdoc renders; overlay + packages.manpages wired.
7. Cache: `just explore-cache-has-pkg .#rustdyn-multi-test` after the build
   has reached the fleet cache; recorded V/R/I in this note. Stop before
   building further if it fails (coordinator's condition).
8. Measurements on a quiet host: the spike's `just bench` against posh is the
   like-for-like number; stage 2 adds the fixtures' cold/warm/edit through
   the same host guard. Recorded here when the host allows.

## Host rules

One nix build at a time; headroom (more than 4 GB available, load1 under 20)
checked in its own turn before each launch; stop at a green local commit if
the host is starved or a merge fails on a credential.
