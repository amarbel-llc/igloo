go-toolchain(7)

# NAME

go-toolchain - version-parameterized Go toolchains for the igloo overlay

# SYNOPSIS

The igloo overlay exposes multiple Go toolchain versions side by side, driven by
a single append-only registry. A downstream flake that applies the overlay gets:

```
pkgs.go              # the NEWEST registered Go version
pkgs.go_1_26_6       # an exact pinned version (coexists with others)
pkgs.mkGoToolchain   # the constructor the aliases above are built from
```

# DESCRIPTION

*go-toolchain* lets the fleet pick a Go point release the day it ships and keep
older releases available while consumers migrate — without editing a package
each time (the "bump replaces via commit" pattern) and without waiting for the
nixpkgs channel to package it.

The mechanism is deliberately light: for a given version, the matching nixpkgs
go_1_<minor> derivation's *version* and *src* are overridden, reusing
nixpkgs' builder, patches, and bootstrap. Point releases within a minor
(1.26.5 -> 1.26.6) share that minor's patch set, so the override is all that is
needed. A Go minor nixpkgs does not package at all is handled by a fork entry
(see *FORK ENTRIES*).

The named *go* / go_<x>_<y>_<z> attributes are thin aliases over
*mkGoToolchain*, so the constructor is the single source of behaviour and the
attributes are the cache-friendly, discoverable surface.

# THE REGISTRY

*pkgs/development/compilers/go-toolchain/registry.nix* is the single source of
truth: an append-only list of entries.

```
[
  { version = "1.26.3"; hash = "sha256-..."; }
  { version = "1.26.6"; hash = "sha256-..."; }
]
```

*pkgs.go* tracks the newest entry (by *builtins.compareVersions*). Every entry
also surfaces as a pinned go_<major>_<minor>_<patch> attribute. The list
is APPEND-ONLY: never rewrite or remove an entry, because consumers pin the
per-version attributes.

# ADDING A VERSION

Use the justfile recipe — it prefetches the source tarball's SRI hash and
inserts a new entry, refusing to rewrite an existing one:

```
just update-go 1.26.6
```

That is the whole flow. `pkgs.go` then resolves to 1.26.6, `pkgs.go_1_26_6`
becomes available, and any prior `pkgs.go_1_26_5` still builds unchanged.

# MKGOTOOLCHAIN

```
mkGoToolchain {
  version ? <newest registry version>,
  base    ? <nixpkgs go_1_<minor> for this version>,
  hash    ? <registry entry's hash>,
  goDrv   ? <registry entry's goDrv, else null>,
}
```

Returns an attribute set bound to one exact toolchain:

```
{
  go;                  # the Go compiler derivation
  buildGoModule;       # nixpkgs buildGoModule.override { go = <that go>; }
  buildGoApplication;  # gomod2nix buildGoApplication with go = <that go>
  mkGoEnv;             # gomod2nix mkGoEnv with go = <that go>
}
```

Use it directly when a consumer wants a whole toolchain in lockstep from one
version knob:

```
tc = pkgs.mkGoToolchain { version = "1.26.6"; };
app   = tc.buildGoApplication { pwd = ./.; src = self; };
shell = tc.mkGoEnv           { pwd = ./.; };
```

When *goDrv* is set it is used verbatim and *base*/*hash* are ignored.

# FORK ENTRIES

A version whose Go minor nixpkgs does not package at all (no go_1_<minor>
base exists to override) can be carried as a fork entry that supplies a
ready-made Go derivation:

```
{ version = "1.27.0"; goDrv = <a go derivation>; }
```

*mkGoToolchain* uses that derivation directly. This is the escape hatch for
staying ahead of nixpkgs' packaging of a new minor; the common point-release
case needs only *{ version; hash; }*. To add support for a new minor via the
light path instead, add its nixpkgs base to *bases* in *default.nix*.

# CONSUMING FROM A DOWNSTREAM FLAKE

Apply the overlay, then reference the toolchain like any nixpkgs Go attribute:

```
pkgs = import nixpkgs { inherit system; overlays = [ igloo.overlays.default ]; };

go = pkgs.go;            # newest; or pin: go = pkgs.go_1_26_6;
app   = pkgs.buildGoApplication { inherit go; pwd = ./.; src = self; };
shell = pkgs.mkGoEnv           { inherit go; pwd = ./.; };
```

Switching an existing consumer from pkgs-master.go_1_26 to the overlay's *go*
is a one-attribute change.

# INTERACTION WITH buildGoApplication

gomod2nix's *buildGoApplication* selects a Go toolchain by scanning go_\*
attributes for the newest one satisfying the consumer's *go.mod* (see
*gomod2nix*(7) *selectGo*). A newly registered go_1_26_6 therefore becomes
the selected default for a *buildGoApplication* call that does not pass an
explicit *go* — this is the intended "default = newest" behaviour. Pass
go = pkgs.go_1_26_5 explicitly to pin a build to an older toolchain.

# CACHING

The dominant cost is building the Go compiler from source, which is unavoidable
for a version *cache.nixos.org* does not yet carry — that is the whole premise
of picking a release early. Once built (locally or pushed to a fleet binary
cache) it is content-addressed by its inputs and reused. Because
pkgs.go_1_26_3 overrides go_1_26 to values nixpkgs already ships, it
resolves to the same store path as go_1_26 and substitutes without a rebuild;
only genuinely newer versions build from source.

# SEE ALSO

*gomod2nix*(7), *eng-versioning*(7), *eng-manpages*(7)

The version-parameterized toolchain design is dispatched from circus#196 /
circus#121 (picking a Go point release the day it ships, keeping older versions
available side by side).
