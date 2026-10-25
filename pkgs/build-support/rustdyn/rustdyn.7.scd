rustdyn(7)

# NAME

rustdyn - per-crate, content-addressed Rust builder for Nix

# DESCRIPTION

rustdyn builds a Cargo workspace as one content-addressed derivation per
crate, the way godyn(7) builds a Go module per package. The crate graph is
derived at evaluation time by running *cargo metadata --offline --locked*
inside a derivation over the vendor directory *rustPlatform.importCargoLock*
assembles from the committed Cargo.lock, and its JSON is imported
(import-from-derivation). Each crate is one nixpkgs *buildRustCrate*
derivation with *\_\_contentAddressed = true*: its dependencies' rlibs are
interpolated by store path, so nix records the edges, and a byte-identical
rlib keeps its store hash and lets its dependents stay cached (early cutoff).

The manifest is a *cargo.nix* at the workspace root (CARGO.NIX MANIFEST
below): Cargo.toml and Cargo.lock are rendered from it at evaluation time
and tracked by no repository, as go.nix replaced go.mod for godyn (FDR 0009
decision c, reversed 2026-10-25; the stage 2 form with a tracked Cargo.toml
and Cargo.lock still builds until consumers have cut over). rustdyn adds
what buildRustPackage cannot: per-crate rebuilds, per-crate test and clippy
lanes, crate outputs shared across repositories, and a graph that cannot
drift because nothing generated is committed.

# buildRustdynWorkspace

```
pkgs.buildRustdynWorkspace {
  pname = "posh";
  src = self;                  # Cargo.toml + Cargo.lock at the root
  # workspaceDir = "rust";     # when the Rust tree is a subdirectory
  tests = true;                # realise every per-harness test run
  postInstall = ''...'';       # manpages, completions: a separate derivation
}
```

Arguments:

- *pname*, *src*, *workspaceDir*: the repository (a flake input or a path)
  and, when the workspace is not at its root, the directory holding
  Cargo.toml and Cargo.lock.
- *version*, *commit*, *memberEnv*: see VERSION EMBEDDING.
- *cargoLock*, *outputHashes*, *allowBuiltinFetchGit*: the lock and how git
  dependencies are fetched, as for buildRustPackage's *cargoLock*.
- *rustc*, *cargo*, *clippy*: the toolchain; igloo's nixpkgs toolchain by
  default, a consumer on rust-overlay passes its own.
- *crateOverrides* (nixpkgs' *defaultCrateOverrides*: the per-crate native
  inputs for openssl-sys, libgit2-sys and friends), *codegenUnits* (16,
  cargo's release default), *release* (true), *extraRustcOpts*.
- *buildInputs*: native inputs for the workspace members' own compiles.
- *bins*, *binaryNames*, *nativeBuildInputs*, *postInstall*: the install step
  (below).
- *tests*, *testEnv*, *nativeCheckInputs*: TESTS.
- *clippyArgs* (*-D warnings*): LINT.

The result is the install derivation; the per-crate work hangs off its
*passthru*:

- *crates.<member>*: each workspace member's crate derivation (outputs *out*
  with its bins, *lib* with its rlib); *allCrates* keys every crate of the
  graph by package id.
- *graphFile*: the metadata JSON the build used; *graph*: the same, parsed;
  *members*, *memberDirs*: the member names and their directories relative to
  the workspace root (what dagnabit's layout lint reads).
- *tests.<member>.<harness>*, *testBins.<member>*, *checkAll*, *testWith*.
- *lint.<member>*, *lintAll*.
- *version*, *commit*, *vendorDir*, *backend* (*"rustdyn"*).

# CARGO.NIX MANIFEST

*manifest = ./cargo.nix* (a path or the attribute set itself) on
*buildRustdynWorkspace* or *buildRustAuto* replaces a tracked Cargo.toml and
Cargo.lock; every other argument is unchanged, and *inputs* names the flake
inputs the manifest's *flakeInputs* refer to:

```
pkgs.buildRustAuto {
  pname = "posh";
  src = self;
  manifest = ./cargo.nix;
  inputs = { inherit galapagos hyphence crap; };
}
```

The file holds cargo's own tables as Nix (TOML and Nix share a data model),
plus two rustdyn keys and one rustdyn table:

- *workspace*: the workspace root's Cargo.toml as data (*workspace.members*,
  *profile*, *patch*, ...).
- *members.<dir>*: that member's Cargo.toml as data. *package.version* may be
  left out: the fleet version (an explicit *version*, else *version.env*,
  else "dev") is filled in. A dependency *{ member = true; }* is rendered as
  a relative *path* to the member of that name; *{ flakeInput = "<name>"; }*
  is rendered as a *path* into the flake input's *packages.<system>.crates*
  output (RFC 0002), under *flakeInputs.<name>.subPath*. A member at the
  workspace root is keyed *"."* and shares the root Cargo.toml.
- *lock*: Cargo.lock as data (*version*, *package* with each registry
  crate's *checksum*); members' versions are filled in like
  *package.version*. Written by the escape hatch, not by hand.
- *flakeInputs.<name> = { input; subPath ? ""; }*: the fleet crates from
  flake inputs; *input* names an entry of the builder call's *inputs*.

rustdyn renders the root and member Cargo.toml files and Cargo.lock into a
copy of *src* (*passthru.cargoSrc*) and builds from that tree on both
backends. A tracked Cargo.toml or Cargo.lock anywhere the renderer writes is
refused at evaluation: cargo.nix is the manifest, and a stale tracked file
would silently lose to it.

*pkgs.rustdynManifest* is the library behind it: *normalize* /
*denormalize* (the fleet version filled in or dropped), *resolve* (the
rendered form, *passthru.cargoResolved*), *render*, *ingestRendered <tree>*
(a rendered or any cargo tree back into the manifest's shape, member paths
folded to *member = true*), *ingestTree { tree; seed; }* (the same with the
version dropped and the seed's *flakeInputs* carried over: a migration),
*renderCargoNix* (the file's text) and *withCargoManifest* (the builders'
entry point).

## The escape hatch: cargoRun, ingest and rustdyn-cargo

A cargo command that needs the network (*cargo add*, *cargo update*,
*cargo generate-lockfile*) or rewrites the tree runs INSIDE nix against the
rendered manifests: *passthru.cargoRun { command; }* is an impure
derivation (network on, never cached, never a pure derivation's input, so
not a flake check) whose *$out/tree* holds the manifests after the command
and *$out/patch* everything else the command changed, as a diff against the
checkout. *passthru.ingest <out>* turns that tree back into cargo.nix
text: member paths fold to *member = true*, flake-input store paths fold
to *flakeInput = "<name>"*, versions equal to the fleet version are
dropped, the previous *flakeInputs* table is kept. Tools the command needs
come through *cargoRunInputs* on the builder call or the run's
*nativeBuildInputs*.

*rustdyn-cargo* wraps both from the checkout (the *godyn-go* twin):

```
rustdyn-cargo -- cargo add serde@1 --features derive      # rewrites cargo.nix
rustdyn-cargo -A packages.x86_64-linux.posh -- cargo update
rustdyn-cargo -n -- cargo generate-lockfile               # build only, print $out
rustdyn-cargo -I .                                        # migrate a tracked Cargo.toml/Cargo.lock into cargo.nix
```

It evaluates the flake from a *git+file:* ref (tracked files as in the
working tree; a new file needs *git add -N*), applies *$out/patch* with
*git apply -p2* after a *--check*, and writes *cargo.nix* from *ingest*.
The first registry dependency of a workspace is exactly this:
*rustdyn-cargo -- cargo add <crate>* fetches the crate once and records its
lock entry and checksum in cargo.nix.

# buildRustAuto (selector)

*pkgs.buildRustAuto* takes the same arguments plus *strategy*: *"native"*
picks rustdyn, *"brp"* picks *rustPlatform.buildRustPackage* over the same
lock, and *null* (the default) picks rustdyn on *rustdynSystems* and
buildRustPackage elsewhere. Both backends are reachable as *passthru.native*
and *passthru.brp*; *passthru.backend* records the choice. Version env,
*postInstall*, *binaryNames* and the inputs are handed to both backends.

# THE INSTALL STEP

Member binaries are gathered into *$out/bin* by a separate, input-addressed
derivation that runs *postInstall* with *nativeBuildInputs* on PATH and then
stdenv's fixup. Editing the install script never relinks a crate. *bins*
limits which member bin targets are installed (default: all); *binaryNames*
renames them (*{ "posh-cli" = "posh"; }*).

# VERSION EMBEDDING

The fleet's Rust convention is a build script reading the version and commit
from the build environment (posh-build, piggy, crap, tacky, smith). rustdyn
sets, for every workspace member's build and its build script:

- *RUSTDYN\_VERSION* and *<PNAME>\_VERSION*: an explicit *version* argument
  wins; else a *version.env* in the workspace dir (declaring
  *<PKG>\_VERSION=<sem>*) is auto-read; else *"dev"*.
- *RUSTDYN\_COMMIT* and *<PNAME>\_COMMIT*: the flake input's *rev* /
  *shortRev*, else *"unknown"*; override with *commit*.
- any *memberEnv* attributes (posh's build script reads *POSH\_GIT\_SHA*).

*<PNAME>* is *pname* upper-cased with hyphens as underscores. The resolved
values are *passthru.version* and *passthru.commit*. Dependencies' build
scripts do not see these variables.

# TESTS

Per workspace member, one derivation (*testBins.<member>*) compiles every
harness with *buildRustCrate*'s *buildTests*: the lib's unit tests, each
tests/\*.rs (or *tests/<dir>/main.rs*) integration test, each bin's unit
tests, plus the member's real binaries so *CARGO\_BIN\_EXE\_<name>* resolves at
compile time. Dev-dependencies are linked for this variant only, so a test
edit leaves the member's normal rlib untouched.

Then one content-addressed run derivation per harness
(*tests.<member>.<harness>*): the harness runs from a copy of the member's
source directory (cargo's cwd for tests) with *CARGO\_MANIFEST\_DIR* set,
*testEnv* exported and *nativeCheckInputs* on PATH; pass/fail is the build
result, *$out/log* the output. *checkAll* realises every run and lists one
*ok <member>/<harness>* line per run; *tests = true* makes the package itself
depend on it.

Because runs are content-addressed, an unchanged test cone never re-runs; a
passing flaky test caches, so rustdyn tests must be hermetic and
deterministic. Runtime flags belong to *testWith*:

```
nix build --impure --expr '(builtins.getFlake (toString ./.)).packages.x86_64-linux.posh.passthru.testWith { crate = "posh-term"; testFlags = [ "--nocapture" "ext" ]; }'
```

Harness names: the lib harness is *<libname>-<metadata>* (buildRustCrate's
symbol-hash suffix), an integration test is its file's stem, a bin's unit
harness is the bin's name. Doctests are not run (a later lane).

# LINT

*lint.<member>* compiles the member once more with clippy-driver standing in
for rustc: a shim whose *bin/rustc* execs *clippy-driver* with the real
rustc's sysroot. Dependencies are the normal rlibs, so an edit re-lints only
its own cone, and the lane's inputs never include a clippy build of a
third-party crate. buildRustCrate's default *--cap-lints allow* is lifted to
*forbid* for this derivation so *clippyArgs* (*-D warnings* by default, the
fleet's *cargo clippy -- -D warnings* gate) fail the build. *lintAll*
realises every member's lint and lists *ok <member>* per member. Suppressions
are cargo's own: *#[allow(...)]* or a *[lints]* table in Cargo.toml (the
latter is translated to rustc flags by buildRustCrate).

# CACHE

Every crate, test-bin and run derivation is content-addressed, so a consumer
host substitutes one only when the cache serves both its NAR and the
realisation record mapping the derivation to that output. igloo's
*just explore-cache-has-pkg <installable>* probes a cache for every floating
CA derivation in a package's closure (realisation, signed narinfo, fetchable
NAR). Run it after a build has had time to reach the fleet cache; a host
whose builds are not uploaded rebuilds the whole per-crate closure on the
next machine.

# LIMITATIONS

- A crate is one derivation (lib, bins and build script together), coarser
  than cargo's units. Dependency features are cargo metadata's unified set
  for the whole workspace, and a dependency's target *cfg()* is not
  evaluated: every resolve edge is linked (FDR 0009, decision b).
- Cargo profiles are not read: crates build at *-C opt-level=3* with
  *codegenUnits*; LTO and strip settings in Cargo.toml are not applied.
- A workspace member's derivation sources only its own directory; a member
  that reads files outside it (*include\_str!("../../x")*) needs those files
  inside the member dir or in a path dependency. A path dependency that is not
  a workspace member (or a dependency outside the workspace root) is not
  supported: only members and crates in the vendor directory have a source.
- A bin target and a *tests/\*.rs* file with the same name share one harness
  name; give them different names.
- rustc re-embeds source hashes in the rlib, so a comment-only edit to a
  compiled file still rebuilds the crate's dependents; the cutoff saves
  edits outside the compiled set (tests, docs, data) and everything outside
  the edited crate's cone (stage 1 measurement, FDR 0009).
- Build scripts that shell out to *git* find no repository in the sandbox;
  the rev arrives through the environment instead.
- Cross-system evaluation keeps godyn's import-from-derivation limit
  (igloo#75); systems other than x86_64-linux are unvalidated (igloo#33).
- No doctests, no per-*[[bin]]* feature filtering beyond
  *required-features*, no nextest, no flake-input crate protocol yet (stage
  3).

What stage 2 (2026-10-25) exercised and what it did not, labelled V (seen
in a check), R (read in a record), I (inferred):

- V: path dependencies between members, a build script reading the version
  env, per-harness tests with *CARGO\_BIN\_EXE* and a fixture file, the
  clippy lane on members, rename and *postInstall*, both selector backends,
  on x86\_64-linux, with no registry or git dependency in any fixture.
- R: registry crates (37 of them, one proc-macro, build scripts in five
  crates) built through the same mapper in the stage 1 spike on posh.
- I: native dependencies (openssl-sys, libgit2-sys, pcsc) through
  *crateOverrides*: buildRustCrate's table should carry them, nothing here
  has run it; proc-macro crates with their own build script; git
  dependencies through *outputHashes* or *allowBuiltinFetchGit*; a workspace
  under *workspaceDir*; a root-package workspace. Each needs a fixture or a
  consumer before it is claimed.
- Cache: the fixtures' outputs were not on the fleet cache when probed (V),
  consistent with the same day's godyn finding; whether a second host can
  substitute a rustdyn build at all is open until circus settles how flic's
  builds are uploaded (FDR 0031). Until then, treat cross-host reuse as
  unproven.

# SEE ALSO

godyn(7), gomod2nix(7), *docs/features/0009-rustdyn-per-crate-rust-builds.md*,
*zz-pocs/rustdyn-poc/README.md* (the stage 1 measurements), nixpkgs'
*buildRustCrate* and *importCargoLock*.
