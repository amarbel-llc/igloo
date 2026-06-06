# amarbel-llc/igloo

A small overlay flake on top of upstream [NixOS/nixpkgs](https://github.com/NixOS/nixpkgs).

`igloo` is the workspace's shared Nix build-support layer: it consumes
nixpkgs as a flake input and exposes build helpers, pins, and package
additions for the amarbel-llc repos that wire it in as their `nixpkgs`
input. It exposes:

- `legacyPackages.<system>` — the upstream pkgs set with the overlay applied
  (drop-in replacement for consumers that use this flake as their `nixpkgs`)
- `overlays.default` — composed overlay (pins + amarbel-specific packages)
- `overlays.amarbelPackages` — amarbel-specific package additions only
- `packages.<system>` — curated subset for `nix run .#foo` ergonomics
- `checks.<system>` — eval coverage for fork-specific packages
- `lib`, `nixosModules` — re-exported from the underlying nixpkgs

## Layout

| Path                                       | Contents                                                  |
| ------------------------------------------ | --------------------------------------------------------- |
| `flake.nix`                                | Inputs and outputs of this overlay flake                  |
| `overlays/`                                | Overlay composition                                       |
| `overlays/default.nix`                     | Auto-discovers `pins/` and combines with amarbel-packages |
| `overlays/amarbel-packages.nix`            | amarbel-specific package additions                        |
| `overlays/pins/`                           | One file per upstream package override                    |
| `pkgs/build-support/gomod2nix/`            | gomod2nix builder library + CLI                           |
| `pkgs/build-support/godyn/`                | godyn per-package Go builder (graph-driven, see godyn(7)) |
| `pkgs/build-support/bun2nix/`              | bun2nix builder library                                   |
| `pkgs/build-support/fetch-gguf-model/`     | GGUF model fetcher                                        |
| `docs/decisions/`                          | Architecture Decision Records (ADRs)                      |
| `docs/features/`                           | Feature Design Records (FDRs)                             |
| `zz-pocs/`                                 | Proof-of-concept experiments                              |

## Using as a consumer

### Drop-in (single input)

```nix
{
  inputs.nixpkgs.url = "github:amarbel-llc/igloo";
  outputs = { nixpkgs, ... }: {
    packages.x86_64-linux.foo = nixpkgs.legacyPackages.x86_64-linux.claude-code;
  };
}
```

This is the simplest case. Whatever `nixpkgs` SHA the overlay flake pins to
becomes your nixpkgs.

### Override the underlying nixpkgs

If you want to control the upstream nixpkgs version yourself:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    amarbel.url = "github:amarbel-llc/igloo";
    amarbel.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, amarbel, ... }: {
    packages.x86_64-linux.foo = amarbel.legacyPackages.x86_64-linux.claude-code;
  };
}
```

### Overlay-only (compose with your own pkgs)

```nix
let
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    overlays = [ amarbel.overlays.default ];
    config.allowUnfree = true;
  };
in pkgs.claude-code
```

## History

`igloo` began as a full fork of NixOS/nixpkgs and was reduced to this
overlay flake before being renamed. The pre-rename git history (the
fork-era commits) lives in the archived
[`amarbel-llc/nixpkgs`](https://github.com/amarbel-llc/nixpkgs) repository.

## License

See [`COPYING`](./COPYING).
