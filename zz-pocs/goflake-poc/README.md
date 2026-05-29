# goflake-poc

Proof-of-concept: source a Go module dependency from a nix flake input.

## Hypothesis

A consumer Go module whose `go.mod` declares

```
require github.com/poc/lib v0.0.0-00010101000000-000000000000

replace github.com/poc/lib => ./.flake-inputs/poc-lib
```

can be built end-to-end inside the nix sandbox, with no network access and no
`go.sum` entry for the replaced module, as long as the nix builder symlinks
the flake input's source into `./.flake-inputs/poc-lib` before invoking
`go build`.

The pseudo-version `v0.0.0-00010101000000-000000000000` is the minimum
syntactically-valid sentinel that `module.CanonicalVersion` (and thus
`modfile.Parse` with a nil fixer) accepts. Its actual content is irrelevant —
the `replace` directive overrides resolution.

## Layout

- `main.go` + `go.mod` — consumer; imports `github.com/poc/lib` and prints
  its `Sentinel` constant.
- `upstream/` — toy "upstream Go library" (own `go.mod`, exports
  `Sentinel = "FLAKE_INPUT_OK_v1"`). Wired into `flake.nix` as a non-flake
  `path:` input.
- `flake.nix` — declares `poc-lib` input pointing at `./upstream`, exposes
  `packages.default` (buildGoModule) + `packages.via-gomod2nix`
  (buildGoApplication) and a devShell with `go`.
- `default.nix` — buildGoModule variant; `preBuild` symlinks
  `${pocLibSrc}` into `.flake-inputs/poc-lib`.
- `default-via-gomod2nix.nix` — buildGoApplication variant; documents the
  structural mismatch with the bridge pattern (see Findings).
- `gomod2nix.toml` — minimal (just `schema = 3`) for the
  buildGoApplication variant.
- `justfile` — `explore`-group recipes for each phase.
- `.flake-inputs/` — gitignored; populated by the builder (or by
  `just host-build` for the phase-1 sanity check).

## Phases

1. **Host sanity** (`just host-build`): inside the devShell, symlink
   `.flake-inputs/poc-lib -> ../upstream`, then `go build && ./result-host`.
2. **Nix build via buildGoModule** (`just nix-build`): build via stock
   nixpkgs `buildGoModule`. The derivation's `preBuild` does the symlink
   to `${pocLibSrc}` (the flake input's /nix/store path).
3. **Nix build via buildGoApplication** (`just nix-build-via-gomod2nix`):
   the same pattern via the fork's `buildGoApplication`. Surfaces a
   structural mismatch — see Findings.

## Findings

### Phase 1: PASS

Bare `go build` accepts the sentinel pseudo-version
`v0.0.0-00010101000000-000000000000` and resolves `replace =>
./.flake-inputs/poc-lib` through the symlink to `../upstream` without
complaint. No network, no `go.sum` entry needed for the replaced module.

### Phase 2: PASS with two non-default knobs

`buildGoModule` works *if and only if*:

1. `vendorHash = null` **and** `proxyVendor = true`. The `proxyVendor`
   flag suppresses buildGoModule's auto-appending of `-mod=vendor` to
   `GOFLAGS` (see
   `nixpkgs/pkgs/build-support/go/module.nix` line ~232). Without it, Go
   demands a `vendor/modules.txt` that doesn't exist.
2. `subPackages = ["."]`. Without it, buildGoModule's subPackage
   auto-discovery walks into `./upstream/` (a different Go module) and
   `./.flake-inputs/poc-lib/` (the symlinked replace target, also a
   different module) and fails with "main module does not contain
   package …".

With both, the binary builds and prints `FLAKE_INPUT_OK_v1`. The
preBuild-driven symlink `ln -sfn ${pocLibSrc} .flake-inputs/poc-lib`
fully works.

### Phase 3: PASS via `goFlakeInputs`

`buildGoApplication` now accepts a `goFlakeInputs` arg: a map from Go
module path to flake-input source. When non-empty, the builder:

1. Synthesizes a merged `go.mod` (via `mkMergedGoMod`) with sentinel
   pseudo-version `require` + absolute `/nix/store` `replace` lines.
2. Unions the consumer's `gomod2nix.toml` with each flake input's via
   `mergeGomod2nixTomls`.
3. Symlinks the absolute path directly into `vendor/<module>` from
   `localReplaceCommands` (no `pwd + "/${value.path}"` re-rooting).
4. Swaps the source's organic `go.mod` for the merged one via a
   `preBuild` prelude, so the in-sandbox build sees the synthetic
   directives.

The consumer's `go.mod` no longer carries the `require`/`replace` lines
— they're injected. See `default-via-gomod2nix.nix`:

```nix
buildGoApplication {
  # ...
  goFlakeInputs = {
    "github.com/poc/lib" = pocLibSrc;
  };
}
```

## What this proves

- **The flake-input-bridge pattern is structurally sound**: Go itself
  has no problem with a sentinel `require` + local-path `replace` + a
  build-time-populated symlink. Phase 1 confirms this in isolation;
  phase 2 confirms it inside a nix sandbox via `buildGoModule`.
- **The pattern works with stock nixpkgs today** via `buildGoModule` +
  `proxyVendor = true` + `subPackages = ["."]` + a `preBuild` symlink.
- **The fork's `buildGoApplication` needs a new arg** to participate.
  The shape is sketched in the FDR (`goFlakeInputs`); this POC supplies
  the concrete failure mode that motivates it.
