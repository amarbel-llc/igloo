# rustdyn stage 2.5 — the cargo.nix manifest (design note, 2026-10-25)

FDR 0009 decision (c) was reversed by the operator on 2026-10-25: no fleet
Rust repository tracks a Cargo.toml or Cargo.lock; a `cargo.nix` at the
workspace root is the manifest, and rustdyn renders both files at
evaluation time. This note fixes the file's shape and what the builder does
with it before any code; the fixtures come first, then the code. Labels as
in the triage note (V observed, R read, I inferred).

## Shape: the TOML tables as Nix, plus two Nix-only tables

TOML and Nix attribute sets are the same data model (tables, arrays,
strings, integers, booleans), so cargo.nix carries the manifests *as they
would be written*, not a re-invented schema. `builtins.fromTOML` ingests a
rendered file in one call (V: a builtin since Nix 2.1); `pkgs.formats.toml`
renders one (R: nixpkgs' `formats.toml` generates TOML from an attribute
set). What cargo would read is therefore round-trippable by construction,
and the escape hatch's ingest is a `fromTOML` per file.

    {
      # The workspace root's Cargo.toml, verbatim as data.
      workspace = {
        workspace = { resolver = "2"; members = [ "crates/posh" "crates/posh-term" ]; };
        profile.release = { lto = "thin"; strip = true; };
      };

      # One entry per member, keyed by its directory: that member's Cargo.toml.
      members."crates/posh" = {
        package = { name = "posh"; version = "0.4.0"; edition = "2021"; };
        dependencies = {
          serde = { version = "1"; features = [ "derive" ]; };
          posh-term = { member = true; };                                # path = "../posh-term", written by the renderer
          galapagos = { flakeInput = "galapagos"; };                       # RFC 0002: path = "<input's crates output>/<flakeInputs.galapagos.subPath>"
        };
        dev-dependencies = { };
        build-dependencies = { };
        features = { default = [ ]; };
        lints.clippy.all = "warn";
      };

      # Cargo.lock as data: the registry crates with their checksums (the only
      # hash bookkeeping, as Cargo.lock has today), path packages without a
      # source. Written by the escape hatch, never by hand.
      lock = {
        version = 4;
        package = [
          { name = "serde"; version = "1.0.219"; source = "registry+https://github.com/rust-lang/crates.io-index"; checksum = "…"; dependencies = [ "serde_derive" ]; }
          { name = "posh"; version = "0.4.0"; dependencies = [ "serde" "posh-term" "galapagos" ]; }
        ];
      };

      # Fleet crates from flake inputs (RFC 0002). Name → input + member dir.
      flakeInputs = {
        galapagos = { input = "galapagos"; subPath = "v2-rust"; };
      };
    }

Two keys are Nix-only and rewritten by the renderer: `member = true`
becomes `path = "<relative dir>"` (so a member can move without editing
every dependent), and `flakeInput = "<name>"` becomes `path =
"<store path of the input's crates output>/<subPath>"` (RFC 0002). Every
other key is cargo's own and passes through.

`version.env` stays the fleet's version source (eng-versioning(7)): the
renderer writes `package.version` from `resolveVersion` when a member
leaves it out, so one file carries the version.

## What the builder does

- **Render.** `withCargoManifest { manifest; inputs; src; }` (the
  `godynManifest.withManifest` twin) builds a `<pname>-cargo-src` tree: the
  consumer's `src` with the rendered `Cargo.toml` at the root and in every
  member directory, and the rendered `Cargo.lock`. It rejects a tracked
  Cargo.toml or Cargo.lock in `src` with a message naming the file and the
  escape hatch, as `withManifest` rejects a tracked go.mod (FDR 0008). The
  stage 2 builder then runs unchanged on that tree (`buildRustdynWorkspace
  { src = rendered; … }`), and `buildRustAuto` hands the same tree to
  `buildRustPackage`.
- **Lock.** `importCargoLock` reads the rendered lock (`lockFileContents`,
  which it already accepts, V: import-cargo-lock.nix). A `flakeInput` or
  `member` dependency appears in the lock as a path package (no `source`),
  which `importCargoLock` ignores (V: it vendors only packages with a
  `source`), and `cargo metadata --locked` accepts because the rendered
  Cargo.toml's `path` agrees.
- **Ingest.** `ingestCargo { tree }` reads a Cargo.toml per member and the
  Cargo.lock with `fromTOML`, folds `path` dependencies that point at a
  member back into `member = true`, keeps everything else as data, and
  returns the cargo.nix attribute set; `renderCargoNix` prints it as the
  file (the godyn `renderGoNix` twin, nixfmt-stable).
- **Escape hatch.** `passthru.cargoRun { command; }`: an impure derivation
  (`__impure`, network on, never cached, as `goRun`) that runs a cargo
  command in the rendered tree and outputs the resulting Cargo.toml and
  Cargo.lock; `rustdyn-cargo add serde@1`, `rustdyn-cargo update`,
  `rustdyn-cargo ingest` wrap `cargoRun` and `ingest` over a `git+file:`
  ref of the dirty tree, writing cargo.nix back (the `godyn-go` twin). The
  stage 1 spike's measurement that `cargo metadata` runs in a second
  applies to the inner loop.
- **Checks.** Fixtures under `tests/manifest/`: a two-member workspace with
  a registry dependency (one, small, with its checksum in `lock`), a
  `member = true` dependency and a version from version.env; assertions:
  the rendered Cargo.toml and Cargo.lock equal committed golden files
  (`rustdyn-manifest-render-test`), ingest of the golden files equals the
  cargo.nix (`rustdyn-manifest-ingest-test`, the round trip), a tracked
  Cargo.toml is refused (`rustdyn-manifest-tracked-test`,
  `testBuildFailure'`), and the stage 2 checks run on the rendered tree
  (`rustdyn-manifest-build-test`, `-tests-test`, `-lint-test`). The
  registry fixture needs network once to record the checksum: the escape
  hatch's first real use.

## Open points, labelled

- Whether `pkgs.formats.toml` prints arrays of tables in the shape cargo
  expects for `[[package]]` in Cargo.lock, and whether its float/datetime
  handling matters for any manifest key (I; the render fixture settles it).
- `[patch]` and `[replace]` tables: passed through as data; whether any
  fleet workspace uses them (I: none read so far).
- Profiles (`lto`, `strip`) are rendered into the root Cargo.toml and
  honoured by `buildRustPackage`; buildRustCrate ignores them (rustdyn(7)
  LIMITATIONS, unchanged).
- The dev loop without ambient cargo: `rustdyn-cargo` is the only path to a
  rendered tree a developer can read; rust-analyzer over it is igloo#85's
  shape and not in this stage (operator's call, 2026-10-25).
