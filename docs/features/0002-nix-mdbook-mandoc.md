---
status: exploring
date: 2026-05-02
promotion-criteria: |
  exploring → proposed: the tracer iteration (the `language/` subtree, ~19
  pages) renders cleanly with one converter choice — lowdown, pandoc, or
  go-md2man — and that choice plus the rationale is recorded in this FDR's
  More Information section. Cross-references between language pages render
  to readable roff (broken links allowed; mangled section bodies are not).

  proposed → experimental: all ~95 in-scope pages render. `pkgs.nix-manual`
  builds in this overlay's CI (`nix flake check`). At least one downstream
  consumer in the fork's environments — a NixOS module, a home-manager
  profile, or a shell.nix — installs `nix-manual` and exercises
  `man nix-manual-language-syntax` etc. in normal use.

  experimental → testing: rendered output read side-by-side with the
  upstream HTML manual on at least the `language/`, `store/`, and
  `protocols/` subtrees; obvious roff bugs (broken cross-refs, mangled
  code blocks, missing sections, mojibake) filed as issues. The first
  `nixpkgs.nix.src` bump after acceptance regenerates without manual
  intervention or new sed passes.

  testing → accepted: stable enough to be the recommended way to read
  the nix manual offline in this fork's environments. `nix.man` (from
  FDR 0002's predecessor commit) and `nix-manual` together cover the
  full official nix manual surface as installable manpages.
---

# Nix mdbook manual as mandoc manpages

## Problem Statement

Upstream `nix` (and DeterminateSystems' fork) ships a substantial offline
manual as an mdbook source tree under `doc/manual/source/` — Nix language
reference, store/derivation/file-system-object concepts, on-disk and wire
protocols, system architecture, advanced operator topics, contributor
docs. The official build pipeline produces an HTML site and a small set of
manpages **only for the command reference** (`nix-build(1)`, `nix-store(1)`,
`nix.conf(5)`, etc., as exposed by `nixpkgs.nix.man` and surfaced in this
overlay via `packages.<system>.nix-man` per commit `bc09e11ab802`). Roughly
95 of the manual's ~145 markdown pages — everything outside `command-ref/`
and `release-notes/` — exist as **HTML only**. There is no offline,
shell-native way to read the Nix language reference, the store protocol,
or the architecture chapter on a machine that has `nix` installed.

This fork's authors prefer reading reference material as manpages
(searchable via `apropos`, navigable via mandoc's pager, available in
`devshell` environments without a browser). The gap is that the upstream
mdbook tree has no manpage output target for non-command content. This
FDR scopes a build-time pipeline that fills the gap as an additive
package in this overlay, leaving upstream nix's own manpage generation
untouched.

**Status is `exploring`**: the converter choice is undecided pending a
tracer iteration on the `language/` subtree (see Limitations), and route
2 (post-preprocessor markdown via an mdbook backend) has a viability
question — see the same section. No code has been written.

## Interface

The intent (not yet implemented) is to expose two attributes via this
overlay, sourced from `pkgs/build-support/nix-mdbook-mandoc/`:

| Attribute | Source | Purpose |
|-----------|--------|---------|
| `pkgs.buildNixManpages` | new build helper | Reusable function: takes an mdbook source tree + config, returns a derivation whose `share/man/manN/` outputs are the rendered roff pages |
| `pkgs.nix-manual` | the helper applied to `nixpkgs.nix.src` | Ready-to-install manpage bundle covering the whole nix mdbook minus release notes |

`pkgs.nix-manual` would surface in `flake.nix` as both
`packages.<system>.nix-manual` (so `nix profile install .#nix-manual`
works alongside the existing `.#nix-man` from FDR-0002's predecessor) and
in `checks.<system>` (so `nix flake check` builds it and catches
regressions on `nixpkgs.nix.src` bumps).

**Page-name convention.** Generated pages are prefixed `nix-manual-*` to
distinguish them unambiguously from the command-reference manpages
(`nix-store(1)` overview vs. `nix-store(7)` concept page would otherwise
collide on `apropos`). Examples:

| mdbook source | Manpage name |
|---------------|--------------|
| `language/index.md` | `nix-manual-language(7)` |
| `language/syntax.md` | `nix-manual-language-syntax(7)` |
| `language/constructs/lookup-path.md` | `nix-manual-language-constructs-lookup-path(7)` |
| `store/index.md` | `nix-manual-store(7)` |
| `store/derivation/index.md` | `nix-manual-store-derivation(7)` |
| `protocols/derivation-aterm.md` | `nix-manual-derivation-aterm(5)` |
| `protocols/json/store-path.md` | `nix-manual-protocols-json-store-path(5)` |
| `architecture/architecture.md` | `nix-manual-architecture(7)` |

**Granularity rule.** For each subdirectory, `index.md` (if present)
becomes the parent page; sibling `*.md` files become child pages with
hyphen-joined names. Subdirectories one level deeper recurse with
the same rule. This produces ~30 top-level page groups across the
~95 source files, mirroring the mdbook ToC in name structure.

**Section assignment.**

- Section 7 (concepts/overviews) is the default. Used for `language/`,
  `store/`, `architecture/`, `advanced-topics/`, `package-management/`,
  `installation/`, `development/`, and standalone pages
  (`glossary.md`, `quick-start.md`, `c-api.md`, `introduction.md`).
- Section 5 (file formats) for explicit on-disk or wire-format specs
  only: `protocols/derivation-aterm`, `protocols/store-path`,
  `protocols/nix32`, and the entire `protocols/json/` subtree. The
  `protocols/index.md` overview itself stays in section 7.

**Build-time only.** No rendered manpages are checked into this
repository. `pkgs.nix-manual`'s closure regenerates from
`nixpkgs.nix.src` whenever that pin moves. This aligns with FDR-0001's
codegen-as-Nix-derivation philosophy — the reproducible artifact is the
derivation, not a snapshot in git.

**Source pipeline (route 2 — primary).** `buildNixManpages` runs
`mdbook` against the input source tree with a custom backend that emits
post-preprocessor CommonMark — directives (`{{#include}}`,
`{{#hint}}`, etc.) resolved, internal links rewritten. A markdown→man
converter (one of `lowdown`, `pandoc`, `go-md2man`; chosen during the
tracer) renders each chapter. A small post-processor walks the output
and rewrites cross-reference links to `see nix-manual-<other>(N)`
form. Output is laid out under `share/man/man{5,7}/` for stdenv's
default man-cache step.

**Source pipeline (route 1 — contingency).** If no off-the-shelf
mdbook backend produces clean enough CommonMark (mdbook-pandoc emits
pandoc-flavored markdown, not vanilla; alternatives may not exist),
fall back to reading the raw `doc/manual/source/*.md` directly,
implementing a small preprocessor for the directives nix actually
uses, and feeding the result to the same markdown→man converter.

## Examples

Installing into a profile, alongside the existing `nix-man`:

```bash
$ nix profile install .#nix-man      # command reference (already merged)
$ nix profile install .#nix-manual   # everything else (this FDR)
```

Reading the rendered output:

```bash
$ man nix-manual-language-syntax
$ man nix-manual-store-derivation
$ man 5 nix-manual-derivation-aterm
$ apropos -s 7 nix-manual            # discover the full set
```

Composing in a NixOS module or home-manager profile:

```nix
{ pkgs, ... }:
{
  home.packages = [
    pkgs.nix-man      # nix-build(1), nix-store(1), nix.conf(5), nix-daemon(8)
    pkgs.nix-manual   # nix-manual-language(7), nix-manual-store(7), …
  ];
}
```

Re-running the helper against a different mdbook source (e.g.
DeterminateSystems' fork, if that ever becomes desirable):

```nix
let
  nix-manual-detsys = pkgs.buildNixManpages {
    src = inputs.nix-src-detsys;
    pname = "nix-manual-detsys";
    # Override section assignment, naming prefix, etc. via attrs.
  };
in
  nix-manual-detsys
```

(The `buildNixManpages` parameter shape is illustrative only — the
final API will be settled during the tracer.)

## Limitations

- **Status is `exploring` for real reasons.** No code is written. The
  numbers in this FDR (~95 pages, ~30 top-level groups) are derived
  from listing `doc/manual/source/*.md` in the upstream
  `NixOS/nix@2.34.6` tree at the time of writing; they will drift as
  nix evolves.

- **Converter is undecided.** `lowdown`, `pandoc`, and `go-md2man` are
  all viable. `lowdown` matches nix's existing command-reference
  manpages stylistically (upstream's `doc/manual/generate-manpage.nix`
  drives a lowdown-based pipeline) and keeps closure size small.
  `pandoc` handles edge cases (math notation, complex tables) that the
  others may degrade or break on. `go-md2man` is the simplest single
  binary but supports the narrowest markdown subset. Tracer iteration
  on `language/` decides.

- **Route 2's mdbook backend may not exist off-the-shelf.**
  `mdbook-pandoc` emits pandoc-flavored markdown; `mdbook-man` exists
  but produces roff directly (which is route 4 territory and was
  rejected). A backend that emits clean CommonMark with directives
  resolved is the ideal but may need to be written. If the cost of
  writing one approaches the cost of route 1's preprocessor, switch
  to route 1.

- **Cross-reference rewriting needs a post-processor.** mdbook
  internal links of the form `[text](./other.md)` or
  `[text](./other.md#anchor)` won't render usefully in roff out of
  the box — the converter will emit raw URLs or stripped link text.
  A post-converter pass needs to walk the rendered roff (or
  intermediate markdown, if simpler) and rewrite link bodies to
  human-readable `(see nix-manual-<other>(N))` references. The
  exact rewriting scheme is undesigned — it depends on whether the
  source-level links are visible to a post-processor in the chosen
  pipeline.

- **Math rendering will degrade.** `store/math-notation.md` uses
  TeX-style math fences. mandoc does not render math; the best case
  is ASCII-ish fallback (`pandoc --to=man` lowers `$x = y$` to a
  plain text run; `lowdown` and `go-md2man` may strip them entirely).
  Acceptable as long as the converter doesn't crash and the
  surrounding prose stays readable.

- **mdbook directive coverage is unaudited.** Beyond `{{#include}}`
  and `{{#hint}}`, nix's mdbook source uses other directives that
  haven't been catalogued. Whichever route ends up in use, untested
  directives may leak through as literal text (`{{#foo …}}`) and
  need a sed pass at the end of the pipeline. Tracer iteration on
  `language/` will surface most of them; later subtrees may surface
  more.

- **Versioning policy is "follow nixpkgs."** When `nixpkgs.nix.src`
  bumps, `pkgs.nix-manual` rebuilds against the new source. There is
  no rendered-output diffing in CI (nothing's checked in). Breakage
  surfaces as a `nix flake check` failure on the `nix-manual` build,
  not as a documentation regression in a PR diff. This is a deliberate
  trade — see "Build-time only" in Interface for the rationale.

- **Page-name length.** `nix-manual-protocols-json-store-object-info(5)`
  is unwieldy. The hybrid granularity rule is what produces these
  long names. The alternatives (one fat page per top-level dir; one
  page per source file with no hierarchy collapse) were rejected
  during scoping; long names are the cost of preserving the mdbook
  ToC structure. A future FDR could revisit if the names prove
  unusable.

- **No interaction with `nix.man` from FDR-0002's predecessor.** The
  two packages are deliberately independent — `nix-man` is upstream's
  own command-reference manpages; `nix-manual` is everything else.
  Installing both is the expected default. No attempt is made to
  detect overlap or de-duplicate.

## More Information

- **Predecessor commit:** `bc09e11ab802`
  (`flake: expose nix.man as packages.<system>.nix-man`). Surfaces
  upstream's command-reference manpages as a flake package; this FDR
  covers the rest of the manual.
- **Sibling FDR for the codegen-at-Nix-build-time philosophy:**
  [`docs/features/0001-numtide-go2nix-overlay-builder.md`](./0001-numtide-go2nix-overlay-builder.md).
  Same shape — a derivation produces an artifact at Nix build time
  rather than committing pre-rendered output.
- **Upstream nix manpage pipeline:** `doc/manual/generate-manpage.nix`
  in the `NixOS/nix` repo (verified to exist in the v2.34.6 tree;
  exact contents inspected during implementation). This is the
  reference for how the existing command-reference manpages are
  rendered and is the natural place to look for converter conventions
  to match.
- **Section-number conventions:** `man-pages(7)` for the rationale
  behind the 1/5/7/8 split and the (non-)overlap between sections.
- **mdbook source listing used to size this work:** the
  `NixOS/nix@2.34.6` `doc/manual/source/` tree, queried via GitHub
  REST at FDR-authoring time. Page counts (~95 in scope, ~30
  top-level groups) are snapshots and will drift.
- **Determinate Systems' fork:** `DeterminateSystems/nix-src@v3.15.2`
  was checked during scoping; mdbook content is ~95% identical to
  upstream NixOS/nix at the level relevant to this FDR. Switching
  source repos later is a one-line change to the `src` argument of
  `buildNixManpages`.
