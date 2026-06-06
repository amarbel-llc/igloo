godyn(7) ["amarbel-llc/igloo"]

# NAME

godyn - per-package Go builder (eval-time package graph, no recursive-nix)

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
. *graph.json* is committed alongside *gomod2nix.toml*.
. *buildGodynModule* reads the committed graph purely (no import-from-derivation).

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

Both backends are always reachable via *passthru.native* / *passthru.bga* (force
either without re-plumbing); *passthru.backend* records the choice.

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

- *pname* — package name; also the binary name.
- *src* — the module source root (a flake input); local packages live under it.
- *graphFile* — the committed graph.json produced by godyn-gen (single platform).
- *graphFiles* — per-system graphs as an attrset *{ "<system>" =
  ./godyn-graph.<system>.json; ... }*, selected by *system* at eval time. *go list*'s
  file/import selection honors GOOS/GOARCH build constraints, so a graph is only
  valid for the platform it was generated for (igloo#33) — a module with
  platform-dependent deps (e.g. golang.org/x/sys/unix) MUST use graphFiles to build
  on more than one system. godyn-gen respects GOOS/GOARCH (and CGO_ENABLED) from its
  environment, so every platform's graph can be generated from one host:
  *CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 godyn-gen . godyn-graph.aarch64-darwin.json*.
  Exactly one of graphFile/graphFiles is required.
- *modules* — a gomod2nix.toml; its vendorEnv (third-party sources by import path)
  is derived internally via buildGoApplication. Omit for an all-local module.
- *vendorEnv* — alternatively pass a prebuilt vendor tree directly.
- *version*, *pwd*, *commit* — see VERSION EMBEDDING below.
- *ldflags* — extra *go tool link* flags as a LIST (e.g. *[ "-s" "-w" ]*, or a raw
  *[ "-X pkg.sym=val" ]*).
- *ldflagsX* — the structured *-X* convenience: an attrset *{ "importpath.name" =
  "value"; }* rendered to *-X* tokens, appended last (Go's *-X* is last-wins). A key
  colliding with an already-set *-X* throws unless *overwriteLdflagsX = true*.
- *cc* — a stdenv cc-wrapper, required iff any package is cgo.
- *bridges* — modpath -> go-pkgs SOURCE store path; the bridged module's packages are
  compiled in THIS graph (cross-module composition, approach 2). See CROSS-MODULE.
- *archiveBridges* — modpath -> go-pkgs-of-ARCHIVES store path; the bridged module's
  packages are LINKED from their pre-built archives, not compiled (approach 1).
- *system*, *goVersion* — target tuning.

A module with a *package main* links a binary at *$out/bin/<pname>*; a library
graph (no main) produces a compile-only manifest realising every archive.
*passthru.archiveGoPkgs* exposes this module's per-package archives (laid out as
*<importpath>/pkg.a*) for a downstream consumer's *archiveBridges*.

*//go:embed* is handled automatically: godyn-gen records each package's embed
patterns + files, and the compile step writes an embedcfg and passes
*go tool compile -embedcfg* (literal and simple suffix-glob patterns).

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

# LIMITATIONS

godyn is build-only (use *go test* / buildGoApplication for tests). go:embed
supports literal and simple suffix-glob patterns.

A committed graph is platform-specific (see *graphFiles* above); building a module
with platform-dependent deps from a single graphFile on another system fails in the
per-package compiles (linux-only files on darwin, igloo#33). The builder is
routinely exercised on x86_64-linux; darwin validation is tracked in igloo#33 —
until it lands, multi-platform consumers should gate the godyn backend per system
(e.g. buildGoAuto strategy native on x86_64-linux, bga elsewhere).

# SEE ALSO

*nixgc*(1), *gomod2nix*(7), *mkGoPkgs*(7), *go*(1), *eng-versioning*(7)
