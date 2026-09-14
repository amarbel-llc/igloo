godyn(7) ["amarbel-llc/igloo"]

# NAME

godyn - per-package, content-addressed Go builder for Nix

# DESCRIPTION

*godyn* builds a Go module as ONE content-addressed derivation per package,
wired together by nix string-context: each package's importcfg interpolates its
dependencies' store paths, so nix records the inter-package edges as *inputDrvs*.
nix's own scheduler then sees the whole package DAG at eval time and rebuilds
only the changed nodes on an edit (the merkle-delta), parallelising independent
ones. There is no recursive-nix, no build-time resolver.

Compile-kind (pure / cgo / Plan 9 asm) is derived per package from its file
lists, orthogonally to source-kind (local in-repo / third-party vendorEnv /
bridged go-pkgs). Across the godyn POCs this beat the recursive resolver 4-5x on
incremental edits and beat *buildGoApplication* on local edits (only the changed
cone rebuilds; a comment-only edit early-cuts).

The public surface exposed on *pkgs* is:

- *buildGodynModule* — build a Go module from a committed graph.json
- *buildGoAuto* — pick godyn (dev) vs buildGoApplication (ci) by strategy
- *godyn-gen* — the dev-time graph generator CLI
- *godynStdlib* — the shared CGO_ENABLED=1 Go stdlib derivation, reused by every
  per-package compile (built once, cached normally)

The companion *nixgc*(1) reaps a godyn build's per-package outputs from the store
(e.g. for a cold-build benchmark) without deleting a concurrent build's live
shared inputs.

# THE GENERATE-COMMIT-EVALUATE WORKFLOW

Like *gomod2nix*, godyn splits dev-time discovery from pure evaluation:

. *godyn-gen <module-dir> <out-graph.json> [packages...]* runs
  *go list -deps -json* over the module and writes a committed *graph.json*
  (nodes: import path, dir, file kinds, embed patterns, in-graph imports).
  *packages* defaults to *./...*; pass e.g. *./internal/foo/...* to scope the graph
  to one subtree's transitive closure. Re-run it only when the import structure or
  file set changes — a content-only edit does NOT need a regen (same contract as
  gomod2nix.toml).
+
*godyn-gen* reads *CGO_ENABLED* / *CC* / *GOFLAGS* from its environment (it does not
set them): use *CGO_ENABLED=0* for a pure-Go module so file selection is clean, or
*CGO_ENABLED=1* + *CC* for a cgo module so its CgoFiles populate; *GOFLAGS=-mod=vendor*
when third-party deps are materialised into vendor/. Pin the same env in the
regenerate and drift-check recipes so the output stays byte-deterministic.
+
A consumer that bridges modules via *goFlakeInputs* (RFC 0001) must generate
against the SAME merged go.mod the build uses: *godyn-gen -gomod <go.mod> ...*
resolves the module graph against that file (staged with the module's go.sum;
the tracked go.mod is never touched). Pass *buildGoApplication*'s
*passthru.mergedGoMod*, whose replaces point bridged modules at their flake-version
go-pkgs — otherwise *go list* sees the vestigial *require* version, and the graph
records the wrong files for, or cannot resolve, a bridged package (igloo#67). The
graph stays portable (dirs are module-relative), but regenerate it whenever a
bridged producer's flake.lock rev moves.
. *graph.json* is committed alongside *gomod2nix.toml*.
. *buildGodynModule* reads the committed graph purely (no import-from-derivation).

# DERIVED GRAPHS (no committed graph)

Committing the graph is optional, and not the recommended path (FDR 0008). Omit
*graphFile* / *graphFiles* and pass *modules*, and *buildGodynModule* derives the
graph at evaluation time: it runs *godyn-gen* inside the *buildGoApplication*
sandbox — the merged go.mod for *goFlakeInputs*, the vendored dependencies,
offline — and imports the resulting JSON. Pass *tests = true* to derive the test
graph the same way (*godyn-gen -tests*) instead of committing *testGraphFile*.

```
pkgs.buildGodynModule {
  pname = "myapp";
  src = self;
  modules = ./gomod2nix.toml;   # required to derive
  goFlakeInputs = { ... };      # as for buildGoApplication
  tests = true;                 # derive the test graph too
}
```

- The graph can never drift from the source: it is recomputed whenever the
  source, go.mod, gomod2nix.toml or a bridged input changes.
- It is derived for the system being evaluated, so *graphFiles* is unnecessary.
  The price is import-from-derivation: evaluating another system's packages needs
  a builder for that system — the same limit *goFlakeInputs* consumers already
  have (igloo#75).
- cgo files are included only when *cc* is passed, matching what the builder can
  compile.
- In the sandbox's vendor mode *go list* reports no module for vendored packages;
  *godyn-gen* recovers each one's module root and *go* directive from the vendored
  module's own go.mod, so per-module *-lang* still applies.
- *passthru.graphFile* / *passthru.testGraphFile* expose the graphs a build used,
  committed or derived.

# GO.NIX MANIFEST

A module can describe its dependencies in *go.nix*, a plain Nix attrset in the
module root, instead of a tracked go.mod, gomod2nix.toml and *goFlakeInputs*
(FDR 0008). *buildGodynModule* and *buildGoAuto* take it as *manifest*, render
the go.mod and gomod2nix.toml from it inside Nix, and derive the graph from the
rendered go.mod:

```
# go.nix
{
  module = "code.linenisgreat.com/myapp";
  go = "1.26";
  require."github.com/google/go-cmp" = {
    version = "v0.6.0"; hash = "sha256-..."; go = "1.13";
  };
  flakeInputs."code.linenisgreat.com/tap/go" = { input = "tap"; subPath = "go"; };
  replace = { };
}

# flake.nix
pkgs.buildGoAuto { pname = "myapp"; src = self; inherit inputs; manifest = ./go.nix; }
```

- *require* — third-party modules: *version*, the vendor *hash* (as in
  gomod2nix.toml), optionally the module's own *go* version and *indirect*.
- *flakeInputs* — fleet modules: *input* names a flake input, resolved as
  *inputs.<input>.packages.<system>.go-pkgs* (RFC 0001), plus an optional
  *subPath*. They are bridged exactly like *goFlakeInputs*; no version is stored.
- *replace* — surviving replaces: *{ path; }* or *{ module; version; }*, with an
  optional *oldVersion* for a versioned left-hand side.
- *goFlakeInputOverrides* — *{ <module> = { src; subPath; }; }* supplies a fleet
  module's source when it is not a conventional flake input (fixtures).
- Unknown fields are errors. A manifest module whose *src* still tracks a go.mod
  is rejected, and *manifest* cannot be combined with *modules* or *goFlakeInputs*.
- Builds need no go.sum: the rendered go.mod builds in vendor mode.

# buildGoAuto (selector)

*pkgs.buildGoAuto* picks the backend by intent — godyn for the incremental dev/test
loop (only the changed cone rebuilds), buildGoApplication for cold / CI / release
(no per-package overhead). A pure flake can't read the environment, so *strategy*
is an explicit knob a consumer sets:

```
pkgs.buildGoAuto {
  pname = "myapp";
  src = self;
  graphFile = ./godyn-graph.json;  # godyn backend
  modules = ./gomod2nix.toml;      # both backends
  strategy = "dev";                # "dev"/"native" -> godyn; "ci"/"bga" -> buildGoApplication
  # backend-specific extras: nativeArgs = { ... }; bgaArgs = { subPackages = [ "." ]; ... };
}
```

With no *strategy*, *buildGoAuto* picks godyn on the systems in *godynSystems* —
every system igloo supports (x86_64-linux, aarch64-linux, x86_64-darwin,
aarch64-darwin) — and buildGoApplication only elsewhere: godyn replaces
buildGoApplication's output everywhere (FDR 0007), which stays reachable as
*passthru.bga*. Consumers must not hard-code a system or pin a strategy: select
test lanes and gates by *passthru.backend*.

Both backends are always reachable via *passthru.native* / *passthru.bga* (force
either without re-plumbing); *passthru.backend* records the choice.

A bridged consumer declares *goFlakeInputs* once on *buildGoAuto*, which hands it to
both backends (see *goFlakeInputs* under buildGodynModule). Generate the graph with
*godyn-gen -gomod* against *passthru.bga.passthru.mergedGoMod* (see above).

The install step (*postInstall*, *nativeBuildInputs*) — which godyn follows with
stdenv's fixup (man-page compression, patchShebangs; no strip, the link already
used *-w*), as buildGoApplication does — is likewise declared once on
*buildGoAuto* and handed to both backends. The script sees each backend's own
binary name under *$out/bin* (godyn: *pname*; buildGoApplication: the main
package's directory name), so a script meant for both should use a name the two
agree on, or glob.

# buildGodynModule

```
pkgs.buildGodynModule {
  pname = "myapp";
  src = self;                     # the flake source
  graphFile = ./godyn-graph.json; # committed, from godyn-gen
  modules = ./gomod2nix.toml;     # third-party -> vendorEnv (or pass vendorEnv=)
  # version + commit are injected automatically (see VERSION EMBEDDING);
  # extra flags optional:
  ldflags = [ "-s" "-w" ];
  ldflagsX = { "main.channel" = "stable"; };
}
```

Arguments:

- *pname* — package name; also the binary name when one binary is linked.
- *src* — the module source root (a flake input); local packages live under it.
- *graphFile* — the committed graph.json produced by godyn-gen (single platform).
- *testGraphFile*, *testGraphFiles* — the committed test graph produced by
  *godyn-gen -tests* (single platform / per-system attrset). Optional; enables
  per-package go test. See TESTS below.
- *tests* — with no committed test graph, derive it at evaluation time and enable
  per-package go test (see DERIVED GRAPHS). The derived build graph then also holds
  the packages only tests import (*godyn-gen -test-deps*), e.g. a bridged module's
  package no production code uses; a committed build graph for a tested module
  must be generated with *-test-deps* too.
- *graphFiles* — per-system graphs as an attrset *{ "<system>" =
  ./godyn-graph.<system>.json; ... }*, selected by *system* at eval time. *go list*'s
  file/import selection honors GOOS/GOARCH build constraints, so a graph is only
  valid for the platform it was generated for (igloo#33) — a module with
  platform-dependent deps (e.g. golang.org/x/sys/unix) MUST use graphFiles to build
  on more than one system. godyn-gen respects GOOS/GOARCH (and CGO_ENABLED) from its
  environment, so every platform's graph can be generated from one host:
  *CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 godyn-gen . godyn-graph.aarch64-darwin.json*.
  Omit both to derive the graph at evaluation time instead (needs *modules*; see
  DERIVED GRAPHS).
- *modules* — a gomod2nix.toml; its vendorEnv (third-party sources by import path)
  is derived internally via buildGoApplication. Omit for an all-local module.
- *vendorEnv* — alternatively pass a prebuilt vendor tree directly.
- *manifest*, *inputs*, *goFlakeInputOverrides* — a go.nix module instead of
  *modules*, *goFlakeInputs* and a tracked go.mod; see GO.NIX MANIFEST.
- *version*, *pwd*, *commit* — see VERSION EMBEDDING below.
- *ldflags* — extra *go tool link* flags as a LIST (e.g. *[ "-s" "-w" ]*, or a raw
  *[ "-X pkg.sym=val" ]*).
- *ldflagsX* — the structured *-X* convenience: an attrset *{ "importpath.name" =
  "value"; }* rendered to *-X* tokens, appended last (Go's *-X* is last-wins). A key
  colliding with an already-set *-X* throws unless *overwriteLdflagsX = true*.
- *cc* — a stdenv cc-wrapper, required iff any package is cgo.
- *buildInputs*, *CGO_CFLAGS*, *CGO_LDFLAGS* — cgo inputs, as for
  buildGoApplication: the C libraries cgo packages compile and link against
  (headers, libraries, *.pc* files), and flags appended to every cgo package's,
  split the way *cmd/go* splits them. A package's own *#cgo* directives —
  *CFLAGS*, *CPPFLAGS*, *LDFLAGS* and *pkg-config* — are recorded in the graph and
  resolved at build time (*pkg-config* runs over *buildInputs*), as *cmd/go* does
  before invoking cgo. *buildGoAuto* forwards all three to both backends.
- *tags* — Go build tags (as *go build -tags*); they select files when the graph is
  derived (*godyn-gen -tags*), so every package, including a test's deps, builds
  under them. A committed graph must be generated with the same *-tags*. The stdlib
  is not re-selected. For test-only tags (*//go:build test* helpers shared across
  packages) build the tests from a second instance with *tags = [ "test" ];
  tests = true;*, as *go test -tags test* would; untouched packages are shared (CA).
  *buildGoAuto* forwards *tags* to both backends.
- *testEnv* — environment variables (an attrset) set for every per-package test run.
- *testLdflags*, *testLdflagsX* — link flags for the per-package test binaries only
  (same shapes as *ldflags* / *ldflagsX*), e.g. to burn a fixture's store path into a
  test so *passthru.testBins.<ip>* runs standalone; release links never see them. A
  package's own variable is named by its FULL import path (*-X
  example.com/cmd/foo.fixture=...*), even for package main, because the test
  variant is compiled as *-p <importpath>*.
- *testFiles* — the golden path for tests that read module files outside their
  package (*../../docs/x*): tested package dir (as in *subPackages*) -> list of
  module-relative files or dirs, placed at those paths in that package's test run
  tree, so the relative path resolves as under *go test*. Only the listed files join
  the run's inputs, so per-package incrementality stays. A key naming no tested
  package throws. *buildGoAuto* forwards it to godyn (bga's *go test* already runs in
  the module tree).
- *testModuleTree* — DISCOURAGED last resort: run tests inside the whole module
  source, exactly like *go test*. Every run then depends on every file, so any edit
  re-runs all of the module's tests; evaluation warns. Prefer *testFiles*.
- *modes* — instrumented build modes as cmd/go names them (*[ "race" ]*,
  *[ "msan" ]*, *[ "asan" ]*), each applied like *go build -<mode>*: a mode stdlib, a
  *go list -<mode>* graph, *-<mode>* on every compile and link (external link through
  *cc*, which is required), and for msan/asan *-fsanitize* on cgo C code. *race =
  true* is shorthand for *[ "race" ]*. msan and asan are wired but not yet
  fixture-verified.
- *cover*, *coverMode*, *coverPackages* — coverage instrumentation, as *go build
  -cover* / *go test -cover*: each covered package goes through *go tool cover* and
  compiles with *-coveragecfg*. Covered binaries write counters under *$GOCOVERDIR*.
  With tests, each run writes *$out/covdata* and *passthru.coverage* merges them into
  *covdata/*, *coverage.out* (textfmt) and *percent.txt*. *coverMode* is *set*,
  *count* or *atomic* (default *set*, *atomic* under *race*); *coverPackages* lists
  local import paths (default: every local package). Not yet: cgo and Plan 9 asm
  packages are not instrumented, packages without tests do not appear in
  *percent.txt*, and dependents recompiled for a test are not instrumented.
  *buildGoAuto* forwards these to godyn only.
- *gcflags*, *asmflags* — extra *go tool compile* / *go tool asm* flags for every
  package godyn compiles (local, third-party and bridged — like *-gcflags=all=…*,
  except the stdlib, which is not recompiled).
- *race* — a *-race* build, as *go build -race* / *go test -race*: the graph is
  derived with *go list -race* (the *race* build tag and *runtime/race*), every
  package and test variant compiles with *-race* against a race-instrumented stdlib,
  and every link — binaries and per-package test binaries — uses *-race*. A
  detected data race fails the test run. *buildGoAuto* forwards it to both backends
  (buildGoApplication via buildGoRace).
- *testPreRun* — shell run in every per-package test run right before the test
  binary (the preCheck analog), with the run tree as the working directory: e.g.
  *export HOME=$TMPDIR* or copying a read-only module cache for tests that shell
  out to *go*. *buildGoAuto* forwards it to godyn.
- *testFlags* — arguments for every test binary run, in the binary's spelling
  (*[ "-test.run=^TestFoo$" "-test.count=1" ]*). Several instances differing only
  in *testEnv*/*testFlags* share their test binaries (content-addressed) and run
  them separately, e.g. a fuzz seed sweep. *buildGoAuto* forwards it to godyn.
- *passthru.vendorEnv* — the vendored third-party tree godyn builds from, for
  fixtures that need the same *vendor/* (null for an all-local module).
- *nativeCheckInputs* — tools on PATH for every per-package test run (e.g. git),
  as in buildGoApplication's check phase; *buildGoAuto* forwards it to both
  backends.
- *subPackages* entries are also passed to *godyn-gen* as package patterns, so a
  main under *testdata/* (which *./...* skips) can be selected, as with
  buildGoApplication.
- *dontStrip* — keep DWARF in linked binaries; by default they link with *-w*, the
  equivalent of buildGoApplication's *strip -S*. Each binary's Go build ID — and the
  GNU build ID the linker derives from it — is a hash of its link inputs, so it is
  reproducible and distinct binaries never share one.
- *bridges* — modpath -> go-pkgs SOURCE store path; the bridged module's packages are
  compiled in THIS graph (cross-module composition, approach 2). See CROSS-MODULE.
- *goFlakeInputs* — the RFC 0001 declaration buildGoApplication takes, resolved the
  same way (including bridges inherited through producers' *passthru.goFlakeInputs*)
  into *bridges*: a *{ src; subPath; }* value becomes *<src>/<subPath>*, and an
  explicit *bridges* entry wins. Generate the graph with *godyn-gen -gomod* against the
  matching merged go.mod. A *mkGoPkgs* producer builds under godyn from its own
  *go-pkgs-test* (*src = go-pkgs-test*, *modules = "${go-pkgs-test}/gomod2nix.toml"*,
  *tests = true*) — the RFC 0001 self-consumption contract (godyn-producer-test).
- *archiveBridges* — modpath -> go-pkgs-of-ARCHIVES store path; the bridged module's
  packages are LINKED from their pre-built archives, not compiled (approach 1).
- *system* — target tuning.
- *subPackages* — which main packages to link, as module-relative dirs
  (*[ "cmd/foo" ]*, *"."*), like buildGoApplication's; default: every main package
  in the graph, as *go install ./...*. Every linked binary is named as *go install*
  (and buildGoApplication) names it — the import path's last element (*cmd/foo* →
  *foo*; a major-version suffix is skipped, *…/foo/v2* → *foo*), even for a single
  main — and all are gathered into one *bin/*. *buildGoAuto* forwards it to both
  backends.
- *binaryNames* — explicit binary names keyed by the main package's module-relative
  dir, as in *subPackages* (*{ "cmd/foo" = "bar"; "." = "tool"; }*); a key naming no
  main package throws. Through *buildGoAuto* it applies to both backends (bga's
  binaries are renamed before *postInstall* runs), so names never differ between
  them.
- *goVersion* — the fallback language version. godyn-gen records each package's
  module *go* directive in the graph (1.16 for a module without one), and every
  package compiles at its own module's version (*-lang*, truncated to
  major.minor since *-lang* rejects a patch level such as 1.24.2), as *go build*
  does — a
  module declaring *go 1.21* keeps pre-1.22 loop-variable semantics (igloo#74).
  *goVersion* applies only to graphs from an older godyn-gen that lack the field;
  regenerate them to get per-module versions.
- *postInstall*, *nativeBuildInputs* — the install step, parity with
  buildGoApplication: *postInstall* runs after the link with *$out/bin/<name>* in
  place and the working directory set to a writable copy of *src*, with
  *nativeBuildInputs* (and their setup hooks) available — e.g. running the binary
  to generate manpages or completions, installing extra files, adding symlinks.
  Setting either makes the result a separate install derivation layered on the
  linked binaries, so editing the install script never re-links. Either way a
  module with main packages yields a *bin/*-only result (a copy of each linked
  binary), like buildGoApplication's: package archives stay in the per-package
  derivations, out of the result and its runtime closure.
  Requires a main package.

A module with a *package main* links a binary at *$out/bin/<name>* (named as *go
install* names it, or by *binaryNames*); a library
graph (no main) produces a compile-only manifest realising every archive.
*passthru.archiveGoPkgs* exposes this module's per-package archives (laid out as
*<importpath>/pkg.a*) for a downstream consumer's *archiveBridges*.

*//go:embed* is handled automatically: godyn-gen records each package's embed
patterns, files, and which files each pattern matched (resolved with cmd/go's own
rules: globs, directory patterns, and *all:*), and the compile step writes that
mapping into an embedcfg for *go tool compile -embedcfg*. A pattern resolving to no
files fails evaluation rather than building a binary with an empty embed.FS; a
graph from an older godyn-gen (no per-pattern mapping) only supports literal and
trailing-*\** patterns — regenerate it (igloo#68).

# CROSS-MODULE COMPOSITION (godyn → godyn)

A godyn module B can consume a godyn-built module A. godyn-gen on B already records
A's packages in B's graph (as non-local nodes — go list resolves them via go.mod), so
the SAME B graph supports two consumption modes; B's flake picks one:

- *bridges = { "<A-module>" = <A source go-pkgs>; }* — approach 2, SOURCE: A's
  packages are compiled inside B's graph. Use A's *src* as the value.
- *archiveBridges = { "<A-module>" = A.passthru.archiveGoPkgs; }* — approach 1,
  OUTPUT: A's packages are linked from A's pre-built archives, never recompiled.

The two CONVERGE: godyn keys per-package archives by import path + content-addresses
them, and *-trimpath* canonicalises the source path out of the *.a*, so A's archive is
the same store object either way and the resulting binary is byte-identical — no
duplicated compilation.

*Prefer bridges (source).* It needs no cross-flake toolchain lockstep (B's toolchain
compiles A — a go bump just works), keeps go.mod the single source of truth, and
doesn't drift B's graph on A's internal churn. Reserve *archiveBridges* for when A is
an independently-versioned / published / sealed unit, is closed-source / pre-built, or
is large enough that isolating consumers from its graph matters. (Go archives are
go-version-specific, so archiveBridges requires A and B to share the toolchain.) See
*zz-pocs/godyn-godyn/README.md* for the measured tradeoff analysis.

# VERSION EMBEDDING

Parity with *buildGoApplication* (gomod2nix(7), eng-versioning(7)). The main binary
gets *-X main.version* and *-X main.commit* auto-injected — no per-repo ldflags
boilerplate:

- *main.version*: an explicit *version* argument wins; else a *version.env* in the
  module dir (declaring <PACKAGE>\_VERSION=<sem>, optional *export*) is auto-read;
  else *"dev"*. *pwd* overrides which dir is read (default *src*).
- *main.commit*: the flake input's *rev* / *shortRev*, falling back to *"unknown"*;
  override with the *commit* argument.

The resolved version and assembled ldflag list are exposed as *passthru.version* and
*passthru.ldflags*.

# TESTS

godyn runs go test per package as TWO content-addressed derivations: a test
binary, and a run whose pass/fail is the build result. Generate the committed
test graph alongside the build graph and pass it to buildGodynModule:

```
godyn-gen . godyn-graph.json
godyn-gen -tests . godyn-test-graph.json
```

```
pkgs.buildGodynModule {
  # ... as above ...
  testGraphFile = ./godyn-test-graph.json;  # or testGraphFiles."<system>" = ...
}
```

The test graph has one node per TESTED package: the test file lists, the test
variant's imports (a superset including test-only deps), and the captured
go-generated testmain source (the capture route — *go list -test* materialises
the same \_testmain.go that go test would use, so TestMain, examples with
output, and fuzz targets are wired identically). Like the build graph it is
platform-specific; multi-platform consumers commit one per system (godyn-gen
honors GOOS/GOARCH).

Per tested package the builder compiles the *go list -test* package shape: the
test VARIANT (package sources + in-package \_test.go files, same import path),
the external <pkg>\_test package compiled against the VARIANT's archive (so
test-only exports resolve; the in-graph packages it imports that depend on <pkg>
are recompiled against the variant too, as go test does — godyn-gen records them
as *recompiled*), and the testmain — then links <name>.test (the
testBin derivation) and executes it with cwd = the package source, so testdata/
and golden files resolve (the testRun derivation). A failing test fails the
build with the test's output in the log.

Passthru surface: *tests.<importPath>* (the run derivations),
*testBins.<importPath>* (the binaries — invoke manually for -run / -v / -count),
and *checkAll* (one manifest realising every run). Wire checkAll into flake
checks:

```
checks.<system>.myapp-tests = myapp.passthru.checkAll;
```

Because runs are content-addressed, an unchanged test cone never re-runs — and
the package's normal archive sources only non-test files, so a \_test.go edit
re-runs exactly that package's tests and nothing else (finer than per-package
granularity). The flip side: a PASSING flaky test caches; godyn tests must be
hermetic and deterministic (no network, no clock/order dependence — the same
contract as buildGoModule's doCheck). Runtime flags like -run or -count belong
to *testWith* or manual testBins invocations, not the cached run.

## The inner loop: testWith

*passthru.testWith { dir; testFlags ? [ ]; }* is one tested package's run —
selected by module-relative *dir* — with extra test-binary flags, for the
edit-test loop (FDR 0008). Unlike *tests.<importPath>* it always builds:
*$out/result* is *ok <importPath>* or *FAIL <importPath>*, and *$out/test.log*
holds the binary's output. Evaluate it against a *path:* flake ref so
uncommitted and untracked files are included; only the edited cone rebuilds:

```
nix build --impure --no-link --print-out-paths --expr '
  (builtins.getFlake "path:'$PWD'").packages.${builtins.currentSystem}.myapp
    .passthru.testWith { dir = "internal/foo"; testFlags = [ "-test.run=TestX" "-test.v" ]; }'
```

igloo's *just explore-godyn-test-loop* recipe times this loop.

# VET

godyn vets each package in its own content-addressed derivation, speaking the
*go vet -vettool* (unitchecker) protocol: the tool gets a vet.cfg naming the
package's sources, every import's export data (godyn's per-package archives and
the stdlib), and each dependency's analysis facts — that dependency's own vet
output. Facts therefore chain along the same merkle-delta as the compiles: a
printf wrapper in one package is known to be one when its callers in another
package are vetted, and an edit re-vets only the edited package and its
dependents.

Local packages report findings — any finding fails the build. Third-party and
bridged packages run facts-only (their findings are not yours to fix). Only
non-test sources are vetted. The analyzers default to the toolchain's own
*go tool vet*; pass *vetTool* (a derivation whose mainProgram is a
unitchecker binary) to run a different analyzer suite through the same wiring.

Passthru surface: *vet.<importPath>* (the local packages' vet derivations) and
*vetAll* (one manifest realising every local package's vet). Wire vetAll into
flake checks:

```
checks.<system>.myapp-vet = myapp.passthru.vetAll;
```

# LINT

The lint lane is the same per-package machinery running *godyn-lint*: cmd/vet's
passes plus staticcheck's default-enabled checks (SA, S, ST — staticcheck's own
default selection; quickfix QF suggestions are left out). Findings fail the
build exactly as in the vet lane, and cross-package facts chain the same way
(e.g. staticcheck's deprecation facts from a dependency).

*//nolint* directives are honored with golangci-lint's rules, so an existing
codebase's suppressions carry over:

- *//nolint* (every linter) or *//nolint:a,b* (named ones); a trailing
  *// reason* is allowed; *//nolint:all* is every linter.
- After code, a directive covers its own line; on a line by itself, it covers
  the whole node that starts on the next line (a func, a statement, a field).
- A name matches the analyzer (*printf*, *SA1019*) or the golangci-lint linter
  it runs under: *govet* for vet passes, *staticcheck* for every staticcheck
  code, and the v1 names *gosimple* (S) and *stylecheck* (ST).
- Findings in generated files (*// Code generated ... DO NOT EDIT.*) are dropped.

godyn-lint is built against golang.org/x/tools v0.50 or newer, whose unitchecker
reads each import's *types* (not only its facts) from that import's vetx file.
A tool that declares *passthru.typedVetx* gets that protocol end to end: every
package's run writes a type-bearing vetx; cgo packages are analyzed from cgo's
translated sources, which the compile derivation keeps in *$out/cgo*; and the
standard library gets its own lane — the tool run facts-only over the stdlib in
dependency order (cgo on, translated as *cmd/go* does), once per tool and
toolchain — whose index serves every package's run (*passthru.lintStdVetx*). Graphs from
a current godyn-gen record each package's stdlib imports (*stdImports*), so a
run is handed only the stdlib vetx its import closure reaches (a package that
imports *fmt* gets about 60 of the ~355); an older graph gets the whole index. The toolchain's own *go tool vet* keeps the older
protocol and is fed exactly as before (igloo#71).

*.golangci.yml* is not read: which analyzers run is godyn-lint's suite, and
staticcheck's own *//lint:ignore* directives are not honored. Pass *lintTool*
(a unitchecker binary) to run a different suite.

Passthru surface: *lint.<importPath>* and *lintAll*, like vet.
*pkgs.buildGodynLint* takes buildGodynModule's arguments and returns *lintAll*
directly — the flake-checks shape:

```
checks.<system>.myapp-lint = pkgs.buildGodynLint {
  pname = "myapp";
  src = self;
  graphFile = ./godyn-graph.json;
  modules = ./gomod2nix.toml;
};
```

# LIMITATIONS

Vet and lint: test sources are not analyzed. The toolchain-vet lane (the older
vetx protocol) skips cgo packages; the lint lane analyzes them from cgo's
translated sources. Under a type-bearing vetx tool (see LINT), archive-bridged
packages cannot be analyzed — there are no sources — so their importers fail.

Tests: a cgo or asm package's own tests are not yet supported (igloo#32), nor is
recompiling a cgo, asm or archive-bridged package against a test variant. A pure-Go
package whose tests reach cgo packages is supported: its test binary links
externally with *cc*, like a cgo main.

go:embed patterns resolve per pattern only in graphs from a current godyn-gen; older
graphs support literal and trailing-*\** patterns (see above).

Tests: cgo and asm packages' own tests and embeds referenced only by \_test.go
files are not yet supported (igloo#34). *race* and coverage (*cover*) are
supported, with the coverage gaps listed under *cover*.

A committed graph is platform-specific (see *graphFiles* above); building a module
with platform-dependent deps from a single graphFile on another system fails in the
per-package compiles (linux-only files on darwin, igloo#33). The builder is
routinely exercised on x86_64-linux. It is the default on every supported system,
but building and gating on darwin and aarch64 awaits real builders (igloo#33);
consumers still do not gate the backend per system. Derived graphs are per-system
by construction; evaluating another system's godyn packages needs a builder for
that system (import-from-derivation, igloo#75).

# SEE ALSO

*nixgc*(1), *gomod2nix*(7), *mkGoPkgs*(7), *go*(1), *eng-versioning*(7)
