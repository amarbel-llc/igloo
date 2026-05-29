---
date: 2026-05-23
status: approved
closes:
  - amarbel-llc/nixpkgs#39
  - amarbel-llc/nixpkgs#40
---

# Design: flake-input-go_mod protocol RFC + goSourceFilter helper

## Context

[nixpkgs#39](https://github.com/amarbel-llc/nixpkgs/issues/39) and
[nixpkgs#40](https://github.com/amarbel-llc/nixpkgs/issues/40) accumulated
real-world adoption signal from
[madder#211](https://github.com/amarbel-llc/madder/issues/211) about two
gaps in the `goFlakeInputs`-bridge story:

1. The consumer-side `gomod.nix` convention has stabilized as a recurring
   shape but is not documented as a contract.
2. The producer-side `go-pkgs = self` default in FDR-0004 cache-couples
   the consumer's build closure to non-Go file edits.

Both issues live at the "where do we put this contract?" level, not the
"how does it work?" level. The existing FDR-0003 and FDR-0004 documents
mix journey/discovery notes with normative interface text. Promoting the
normative slice into a dedicated RFC gives downstream adopters a
single, precise reference; the FDRs retain the journey for context.

## Scope

In scope:

- New `docs/rfcs/` directory; this is the repo's first RFC.
- `docs/rfcs/0001-flake-input-go_mod.md` containing the normative
  protocol specification (consumer + producer halves).
- `pkgs.goSourceFilter` helper implemented via
  `lib.sources.sourceByRegex`, exported through the fork's overlay.
- `pkgs.goSourceFilterMiddleware` — thin `src -> src` wrapper for
  composition with the future `mkGoPkgs.middlewares` pipeline.
- scdoc man page for `goSourceFilter` (matches the
  `pkgs/build-support/gomod2nix/gomod2nix.7.scd` precedent).
- FDR-0003 and FDR-0004 thinned to journey-only with a "Status:
  superseded by RFC 0001 for interface specification" header pointing
  at the new RFC.

Out of scope (specified in RFC, implementation deferred):

- `pkgs.mkGoPkgs` implementation. FDR-0004's `exploring` status holds;
  the RFC documents the interface for future implementation. Producers
  can use `goSourceFilter` standalone:
  `packages.${system}.go-pkgs = pkgs.goSourceFilter { src = self; };`.
- `pkgs.dagnabitExportMiddleware` — owned by purse-first.
- Further evolution of `goFlakeInputs` consumer-side semantics beyond
  what FDR-0003 already commits.
- Linter for `buildGoApplication`/`mkGoEnv` calls missing
  `goFlakeInputs` (nixpkgs#41) — explicitly deferred per user request.

## Design

### RFC location and status

- Path: `docs/rfcs/0001-flake-input-go_mod.md`.
- Title: "RFC 0001 — flake-input-go_mod protocol".
- Status: `Draft`. Adopts FDR-0003's `exploring → proposed →
  experimental → testing → accepted` promotion ladder; the RFC and the
  FDRs advance together because they describe complementary slices of
  the same protocol.

### RFC structure

1. Status / promotion criteria / metadata.
2. Abstract — single-paragraph summary of the protocol.
3. Terminology — `producer`, `consumer`, `bridge`, `middleware`,
   `goFlakeInputs`, `go-pkgs`.
4. Protocol overview — two-half story (consumer / producer).
5. Consumer interface: `goFlakeInputs` (lifted from FDR-0003 §
   *Interface*, with normative MUST/SHOULD/MAY language).
6. Producer interface: `go-pkgs` attribute + `mkGoPkgs` helper (lifted
   from FDR-0004 § *Interface*).
7. Source filtering: `goSourceFilter` (new content; closes
   nixpkgs#40).
8. Consumer convention: `gomod.nix` colocation pattern (new content;
   closes nixpkgs#39).
9. Multi-producer closures: `follows` + passthru inheritance (lifted
   from FDR-0003 § *Multi-producer closures*).
10. Limitations (lifted and consolidated from both FDRs).
11. Open questions / future work (e.g. lazy-trees interaction,
    `mkGoEnv` parity verification).
12. References — link back to FDR-0003 and FDR-0004 for journey/POC;
    tracking issues; downstream consumers.

### `goSourceFilter` signature

```nix
goSourceFilter =
  {
    src,
    extras ? [ ],
  }:
  let
    defaultRegexes = [
      ".*\\.go$"
      "^go\\.mod$"
      "^go\\.sum$"
      "^gomod2nix\\.toml$"
    ];
  in
  lib.sources.sourceByRegex src (defaultRegexes ++ extras);
```

Notes:

- Implementation primitive: `lib.sources.sourceByRegex` (existing
  nixpkgs stdlib function in `lib/sources.nix`).
- `extras` accepts **regex strings** (not glob patterns). Nixpkgs
  stdlib does not ship glob-string matching; the closest idiom is
  `sourceByRegex`, which we use directly rather than invent a new
  syntax. Documented examples in the RFC and man page cover the common
  cases: `"^doc/.*"`, `"^VERSION$"`, `".*\\.tmpl$"`.
- Output store-path name: `sourceByRegex` preserves `src.name` via
  `cleanSourceWith`'s default behavior. If `src.name` is `"tommy"`, the
  filtered output is `"tommy"` (not `"tommy-go-source"`). The RFC notes
  this as the documented behavior; if downstream wants a renamed store
  path, they wrap with `lib.cleanSourceWith { name = "..."; src = ...; }`.

### `goSourceFilterMiddleware`

```nix
goSourceFilterMiddleware = src: goSourceFilter { inherit src; };
```

A 1-line wrapper so the filter can be used in a future
`mkGoPkgs { middlewares = [ goSourceFilterMiddleware ... ]; }`
pipeline without forcing producers to write the closure themselves.

### Wiring into the overlay

`overlays/amarbel-packages.nix` extends the existing `callPackage
../pkgs/build-support/gomod2nix { }` block:

```nix
inherit
  (final.callPackage ../pkgs/build-support/gomod2nix { })
  buildGoApplication
  buildGoRace
  buildGoCover
  mkGoEnv
  mkVendorEnv
  mkGoCacheEnv
  goSourceFilter
  goSourceFilterMiddleware
  ;
```

Implementation file: `pkgs/build-support/gomod2nix/source-filter.nix`,
imported from `pkgs/build-support/gomod2nix/default.nix` and re-exported.

### scdoc man page

`pkgs/build-support/gomod2nix/goSourceFilter.7.scd` — section 7
(conventions/protocols). Sections:

- NAME, SYNOPSIS, DESCRIPTION
- ARGUMENTS (`src`, `extras`)
- DEFAULT KEEP-SET
- EXAMPLES (no extras; with `doc/`; with embed targets)
- LIMITATIONS (regex not globs; name preservation behavior)
- SEE ALSO (`gomod2nix(7)`, `lib.sources.sourceByRegex`, RFC 0001)

The existing `gomod2nix-man` derivation in
`overlays/amarbel-packages.nix` will pick this up automatically (it
scans `*.7.scd`).

### FDR transitions

For each of FDR-0003 and FDR-0004:

- Keep status block, promotion criteria, problem statement, POC
  findings, "More Information" section.
- Replace `## Interface` and `## Examples` sections with a notice:
  "**Status:** superseded by [RFC 0001](../rfcs/0001-flake-input-go_mod.md)
  for interface specification. See the RFC for normative MUST/SHOULD/MAY
  language; the discussion below is preserved for context on how the
  shape was discovered."
- Keep one "migration before/after" example each (journey-flavored, not
  normative).
- "Limitations" section: cross-reference the RFC's consolidated
  Limitations; retain FDR-specific limitations that are journey-flavored
  (e.g. POC failure modes).

## Rollback strategy

This is additive infrastructure, not replacement. Dual-architecture
concerns are minimal because no prior `goSourceFilter` exists.

- **RFC document rollback**: `git revert` the RFC-creation commit + the
  FDR-thinning commit. Restores prior state exactly. No production
  state depends on the RFC's existence.
- **Implementation rollback**: remove `goSourceFilter` and
  `goSourceFilterMiddleware` lines from
  `overlays/amarbel-packages.nix`, delete
  `pkgs/build-support/gomod2nix/source-filter.nix`. Producers using
  `pkgs.goSourceFilter` fall back to calling
  `lib.sources.sourceByRegex` directly (3 lines) or to `self`. Adopter
  surface is greppable; no consumers exist outside this fork's own
  docs at design time.
- **Promotion criteria**: inherits FDR-0003's existing
  `exploring → proposed → experimental → testing → accepted` ladder.
  `goSourceFilter` enters `proposed` when the implementation lands;
  promotes to `experimental` when at least one producer (likely tommy,
  the surface that originated nixpkgs#40) adopts it.

## Open questions deferred to the RFC

1. **Lazy-trees interaction.** Theory: `lib.sources.sourceByRegex` /
   `cleanSourceWith` only import matching files into the store, so the
   filter benefit composes with Nix's existing source-import laziness.
   Less certain about interaction with Nix's experimental `lazy-trees`
   feature (Git-input lazy materialization). RFC's *Open Questions*
   captures this as a verification item rather than asserting behavior.
2. **`mkGoEnv` parity.** The filter must apply identically to
   `mkGoEnv` calls so devshell module-graph matches build-time
   module-graph. RFC notes this as a constraint; verification deferred
   until `mkGoPkgs` implementation lands.
3. **Name preservation.** Documented behavior is "preserve `src.name`".
   Whether downstream adopters want `${src.name}-go-source` instead is
   left to the first real adoption (tommy) to surface.

## Implementation order

1. Create `docs/rfcs/0001-flake-input-go_mod.md` with the structure
   above (commit 1).
2. Implement `pkgs/build-support/gomod2nix/source-filter.nix`,
   re-export from `default.nix`, wire into overlay (commit 2).
3. Write `pkgs/build-support/gomod2nix/goSourceFilter.7.scd` and
   verify the existing `gomod2nix-man` derivation picks it up (commit
   3).
4. Thin FDR-0003 and FDR-0004 to journey-only with RFC pointer (commit
   4).
5. Verify via `just` (the merge hook will run this anyway; the
   pre-merge hook IS the CI lane).

`Closes #39` and `Closes #40` appear in the FDR-thinning commit (commit
4) so GitHub auto-closes both issues when the worktree merges.
