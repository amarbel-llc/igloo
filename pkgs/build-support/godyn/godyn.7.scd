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
- *godyn-gen* — the dev-time graph generator CLI
- *godynStdlib* — the shared CGO_ENABLED=1 Go stdlib derivation

# THE GENERATE-COMMIT-EVALUATE WORKFLOW

Like *gomod2nix*, godyn splits dev-time discovery from pure evaluation:

. *godyn-gen <module-dir> <out-graph.json> [packages...]* runs
  *go list -deps -json* over the module and writes a committed *graph.json*
  (nodes: import path, dir, file kinds, embed patterns, in-graph imports).
  Re-run it only when the import structure or file set changes — a content-only
  edit does NOT need a regen (same contract as gomod2nix.toml).
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
- *graphFile* — the committed graph.json produced by godyn-gen.
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
- *bridges* — modpath -> go-pkgs store path for cross-flake source.
- *system*, *goVersion* — target tuning.

A module with a *package main* links a binary at *$out/bin/<pname>*; a library
graph (no main) produces a compile-only manifest realising every archive.

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
supports literal and simple suffix-glob patterns. The builder is currently
exercised on x86_64-linux.

# SEE ALSO

*gomod2nix*(7), *go*(1)
