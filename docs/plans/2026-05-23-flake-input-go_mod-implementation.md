# flake-input-go_mod Protocol RFC + goSourceFilter Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use eng:subagent-driven-development to implement this plan task-by-task.

**Goal:** Ship the first RFC in this fork (`docs/rfcs/0001-flake-input-go_mod.md`) capturing the normative spec for the flake-input-go_mod protocol, implement the `pkgs.goSourceFilter` helper that issue #40 asked for, document the `gomod.nix` consumer convention that issue #39 asked for, and thin FDR-0003 / FDR-0004 to journey-only.

**Architecture:** Two output artifacts. (1) A normative RFC document that absorbs the interface sections from FDR-0003 + FDR-0004 and adds new sections for the gomod.nix consumer convention (#39) and goSourceFilter (#40). (2) A tiny implementation helper (`pkgs.goSourceFilter` + `pkgs.goSourceFilterMiddleware`) backed by the existing `lib.sources.sourceByRegex` stdlib primitive, exported through the fork's overlay alongside the other Go helpers.

**Tech Stack:**
- Nix expression language (helpers live in `pkgs/build-support/gomod2nix/`)
- `lib.sources.sourceByRegex` (existing nixpkgs stdlib — no glob support in nixpkgs lib, confirmed via reading `lib/sources.nix` from master)
- scdoc for the section-7 man page (matches existing `gomod2nix.7.scd` precedent)
- spinclass `merge-this-session` for the final PR-and-merge flow

**Rollback:** Purely additive. `git revert` the RFC commit + helper commit + overlay-wiring commit + FDR-thinning commits to restore the prior state exactly. No existing consumer code depends on `pkgs.goSourceFilter`; downstream falls back to `lib.sources.sourceByRegex` directly (3 lines). FDR pre-thinning state is recoverable from git history.

**Design reference:** `docs/plans/2026-05-23-flake-input-go_mod-design.md` (committed in `7fd3ede11ac7`).

---

## Task 1: Scaffold `docs/rfcs/` with RFC 0001 header + outline

**Promotion criteria:** N/A — new artifact.

**Files:**
- Create: `docs/rfcs/0001-flake-input-go_mod.md` (header + section outline only; content lands in subsequent tasks)

**Step 1: Verify `docs/rfcs/` does not exist**

Run: `ls docs/rfcs 2>&1 || echo "absent"`
Expected: `absent` (directory does not yet exist; `folio.write` creates parents).

**Step 2: Write the RFC scaffold**

The file should start with this frontmatter and outline-only headings (no body content yet):

```markdown
---
status: draft
date: 2026-05-23
promotion-criteria: |
  draft → proposed: at least one producer in this fork adopts `pkgs.goSourceFilter`
  for its `packages.${system}.go-pkgs` flake output; FDR-0003 and FDR-0004 are
  thinned to reference this RFC for normative spec.

  proposed → experimental: tommy (or another producer) publishes
  `packages.${system}.go-pkgs = pkgs.goSourceFilter { src = self; }` and a
  consumer (madder) builds successfully against the filtered output.

  experimental → testing: lazy-trees interaction and mkGoEnv parity for the
  filter are empirically verified.

  testing → accepted: at least two producers carry filtered `go-pkgs` for a
  release cycle without reverting to bare `self`.
---

# RFC 0001 — flake-input-go_mod protocol

## Abstract

(filled in Task 2)

## Terminology

(filled in Task 2)

## Protocol overview

(filled in Task 2)

## Consumer interface: `goFlakeInputs`

(filled in Task 3)

## Producer interface: `packages.${system}.go-pkgs` and `mkGoPkgs`

(filled in Task 4)

## Source filtering: `goSourceFilter`

(filled in Task 5)

## Consumer convention: `gomod.nix` colocation

(filled in Task 6)

## Multi-producer closures: `follows` + passthru inheritance

(filled in Task 7)

## Limitations

(filled in Task 8)

## Open questions

(filled in Task 8)

## References

(filled in Task 8)
```

**Step 3: Stage and commit**

```bash
mcp__plugin_moxy_moxy__grit_add paths=["docs/rfcs/0001-flake-input-go_mod.md"]
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs: scaffold RFC 0001 (flake-input-go_mod protocol)

Establishes the docs/rfcs/ directory and the section outline for the
protocol's normative spec. Body content lands in follow-up commits.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

Expected output: one new file, one commit.

---

## Task 2: RFC body — Abstract, Terminology, Protocol overview

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (Abstract, Terminology, Protocol overview sections)

**Step 1: Fill the three opening sections**

Use these section bodies. Wording derived from FDR-0003's "Problem Statement" + FDR-0004's "Problem Statement", condensed and normative.

- **Abstract**: one paragraph summarizing the two-half story (consumer `goFlakeInputs`, producer `go-pkgs`).
- **Terminology**: bullet list with normative definitions for `producer`, `consumer`, `bridge`, `middleware`, `goFlakeInputs`, `go-pkgs`, `gomod.nix`. Use MUST/SHOULD/MAY language consistent with RFC 2119 for all subsequent normative claims.
- **Protocol overview**: two-paragraph diagram-in-prose explaining that consumer + producer compose end-to-end, with the lockstep-drift class (motivation) as the why.

Key constraint: this section is the high-level overview only. Interface specifics land in Tasks 3-7.

**Step 2: Commit**

```bash
mcp__plugin_moxy_moxy__grit_add paths=["docs/rfcs/0001-flake-input-go_mod.md"]
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: abstract, terminology, protocol overview

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 3: RFC body — Consumer interface `goFlakeInputs`

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (Consumer interface section)
- Reference: `docs/features/0003-bridge-go-flake-inputs.md` § *Interface* (source material, copy + normative-language pass)

**Step 1: Lift FDR-0003's `## Interface` section into the RFC**

Tighten language to MUST/SHOULD/MAY. Cover:

- The `goFlakeInputs` argument shape (`{ "<module-path>" = <derivation-or-{src,subPath}>; ... }`)
- The merge primitive: `go mod edit -replace` at eval time
- Inline derivation arg (no manifest file) — normatively forbid out-of-band declaration mechanisms
- `mkGoEnv` parity: implementations MUST apply the same merge in `mkGoEnv` as in `buildGoApplication`
- Local `go build` outside Nix is unsupported (consumer MUST use `nix develop` or `nix build`)

Also include the schema for the value shape:

```nix
goFlakeInputs :: AttrSet (Derivation | { src :: Derivation; subPath :: String })
```

**Step 2: Commit**

```bash
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: consumer interface (goFlakeInputs)

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 4: RFC body — Producer interface (`go-pkgs` + `mkGoPkgs`)

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (Producer interface section)
- Reference: `docs/features/0004-go-pkgs-producer-convention.md` § *Interface*

**Step 1: Lift FDR-0004's `## Interface` section into the RFC**

Cover:

- The `packages.${system}.go-pkgs` flake-output convention (SHOULD attribute name)
- The `mkGoPkgs { src; middlewares; goFlakeInputs; subPath; }` helper interface (MAY use; `go-pkgs = self` MAY be used for hand-written-only producers)
- Middleware contract: `src -> src`, left-to-right via `foldl'`
- `passthru.goFlakeInputs` attachment for depth-1 transitive inheritance

Mark `mkGoPkgs` as a deferred implementation: "This RFC normatively specifies the `mkGoPkgs` interface; implementation lands in a future PR. Producers MAY use `pkgs.goSourceFilter` standalone as the `go-pkgs` value until `mkGoPkgs` lands."

**Step 2: Commit**

```bash
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: producer interface (go-pkgs + mkGoPkgs)

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 5: RFC body — Source filtering (`goSourceFilter`) — closes #40

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (Source filtering section)

**Step 1: Write the source-filtering section**

Sub-headings:

1. **Rationale** — bare `self` cache-couples the consumer's build closure to non-Go file edits. A filtered `go-pkgs` MUST drop README, scdoc, justfile, .github/, etc.; SHOULD reuse the producer's existing cleanSourceWith filter if one exists; MAY use `pkgs.goSourceFilter` for the common case.
2. **`goSourceFilter` interface** — signature:

   ```nix
   goSourceFilter :: { src :: Path; extras ? [ String ]; } -> Source
   ```

3. **Default keep-set** (normative MUST):
   - `*.go` (suffix match)
   - `go.mod` (exact)
   - `go.sum` (exact)
   - `gomod2nix.toml` (exact)
4. **`extras` semantics** (normative MUST): list of POSIX extended-regex strings, matched against the source-tree-relative path of each file. Examples: `"^doc/.*"`, `"^VERSION$"`, `".*\\.tmpl$"`. NOT glob patterns — nixpkgs stdlib does not ship glob matching; `goSourceFilter` uses `lib.sources.sourceByRegex` under the hood.
5. **Store path naming** — `goSourceFilter` preserves `src.name` (via `cleanSourceWith`'s default). Producers who want a custom name MAY wrap with `lib.cleanSourceWith { name = "..."; src = ...; }`.
6. **`goSourceFilterMiddleware`** — a 1-line `src -> src` wrapper exposing the filter for the `mkGoPkgs.middlewares` pipeline.

**Step 2: Commit**

```bash
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: source filtering (goSourceFilter)

Spec for #40's filtered go-pkgs request. Defines default keep-set
(*.go, go.mod, go.sum, gomod2nix.toml), regex-based extras, and the
goSourceFilterMiddleware wrapper.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 6: RFC body — Consumer convention (`gomod.nix`) — closes #39

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (Consumer convention section)

**Step 1: Write the gomod.nix convention section**

Sub-headings:

1. **Recommended shape** (normative SHOULD when bridging 2+ deps): lift the attrset into `gomod.nix` (or `go/gomod.nix` for polyglot repos) that takes flake inputs as parameters and returns the bridge table. Single-dep bridges MAY remain inline.
2. **Example** (reuse the madder example from issue #39's body):

   ```nix
   # go/gomod.nix
   { tap, tommy, system }: {
     "github.com/amarbel-llc/tap/go" = { src = tap; subPath = "go"; };
     "github.com/amarbel-llc/tommy" = { src = tommy.packages.${system}.go-pkgs; };
   }
   ```

3. **Threading** — every `buildGoApplication` and `mkGoEnv` call that consumes `gomod2nix.toml` MUST receive the same `goFlakeInputs` value (use `inherit goFlakeInputs;` per call). Missing call sites silently resurrect lockstep-drift; see issue #41 for proposed linting.
4. **Why this convention exists** — three reasons from issue #39: (a) discoverability (`cat go/gomod.nix`), (b) drift surface (one grep target), (c) symmetry with producer-side `go-pkgs` (one file each side).

**Step 2: Commit**

```bash
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: consumer convention (gomod.nix colocation)

Documents the gomod.nix pattern that #39 surfaced from madder#211
adoption. Recommends lifting goFlakeInputs into a sibling file when
bridging 2+ deps; single-dep bridges may remain inline.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 7: RFC body — Multi-producer closures

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (Multi-producer closures section)
- Reference: `docs/features/0003-bridge-go-flake-inputs.md` § *Multi-producer closures*

**Step 1: Lift FDR-0003's multi-producer-closures section**

Cover:

- Shared transitive deps: align with `inputs.<producer>.inputs.<dep>.follows = "<dep>"` (existing Nix flake mechanism; the bridge does not replicate version policy)
- Producer-side `passthru.goFlakeInputs` inheritance at depth-1
- Conflict resolution: consumer-declared entries win over inherited

Mark depth-1 as the normative limit; deeper-than-one transitive resolution is deferred to nixpkgs#36's FOD-regen path.

**Step 2: Commit**

```bash
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: multi-producer closures (follows + passthru)

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 8: RFC body — Limitations, Open questions, References

**Files:**
- Modify: `docs/rfcs/0001-flake-input-go_mod.md` (final three sections)

**Step 1: Write Limitations section**

Consolidate from FDR-0003 (caller-managed require line, transitive deps assumption, source-only inputs, no go build outside Nix) and FDR-0004 (multi-module repos, middleware ordering, subPath does not slice middleware input). Mark each as "open" or "deferred" with cross-references to tracking issues.

**Step 2: Write Open questions section**

Three items from the design doc:

1. Lazy-trees interaction (theory: `cleanSourceWith` narrows the imported tree, but interaction with Nix's `lazy-trees` experimental feature is unverified).
2. `mkGoEnv` parity for `goSourceFilter` (deferred until `mkGoPkgs` lands).
3. Store-path name preservation behavior — `${src.name}-go-source` would be more diagnostic; awaiting tommy's adoption signal.

**Step 3: Write References section**

- FDR-0003 (`docs/features/0003-bridge-go-flake-inputs.md`) — journey, problem statement, POC findings
- FDR-0004 (`docs/features/0004-go-pkgs-producer-convention.md`) — journey, problem statement
- POC commit `f99a3ff43278` at `zz-pocs/goflake-poc/`
- Issues #39 (gomod.nix convention), #40 (filtered go-pkgs), #41 (linter follow-up)
- Tracking: nixpkgs#32 (consumer-side implementation), nixpkgs#35 (mkGoPkgs / middleware), nixpkgs#36 (transitive resolution)

**Step 4: Commit**

```bash
mcp__plugin_moxy_moxy__grit_commit message="docs/rfcs/0001: limitations, open questions, references

Completes the RFC body. Consolidates limitations from FDR-0003 and
FDR-0004, captures lazy-trees and mkGoEnv-parity verification items,
and cross-links the originating issues + tracking issues.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 9: Implement `goSourceFilter` and `goSourceFilterMiddleware` (TDD)

**Promotion criteria:** Helper at `proposed` once implementation lands; promotes to `experimental` when first producer (likely tommy) adopts it.

**Files:**
- Create: `pkgs/build-support/gomod2nix/source-filter.nix` (helper definitions)
- Modify: `pkgs/build-support/gomod2nix/default.nix:920-931` (re-export from the trailing `in { inherit ...; }` block)
- Create: `pkgs/build-support/gomod2nix/source-filter-test.nix` (in-tree test fixture using `runCommand` to build a known tree, then assert which files made it through)

**Step 1: Write the failing test**

`pkgs/build-support/gomod2nix/source-filter-test.nix`:

```nix
# Smoke tests for goSourceFilter.
# Build with: nix-build pkgs/build-support/gomod2nix/source-filter-test.nix
{ pkgs ? import ../../.. { } }:
let
  fixture = pkgs.runCommand "go-source-filter-fixture" { } ''
    mkdir -p $out/cmd/example
    echo "package main" > $out/cmd/example/main.go
    echo "module example.com/x" > $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
    echo "# README" > $out/README.md
    mkdir -p $out/doc
    echo "doc" > $out/doc/intro.md
    echo "VERSION" > $out/VERSION
  '';

  basic = pkgs.goSourceFilter { src = fixture; };
  withExtras = pkgs.goSourceFilter {
    src = fixture;
    extras = [ "^doc/.*" "^VERSION$" ];
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";

  basicFiles = builtins.attrNames (builtins.readDir basic);
  basicCmdFiles = builtins.attrNames (builtins.readDir "${basic}/cmd/example");

  withExtrasFiles = builtins.attrNames (builtins.readDir withExtras);
  withExtrasDocFiles =
    if builtins.pathExists "${withExtras}/doc"
    then builtins.attrNames (builtins.readDir "${withExtras}/doc")
    else [];
in
pkgs.runCommand "go-source-filter-tests"
  {
    _ignored = [
      (assert' "basic: keeps go.mod" (builtins.elem "go.mod" basicFiles))
      (assert' "basic: keeps go.sum" (builtins.elem "go.sum" basicFiles))
      (assert' "basic: keeps gomod2nix.toml" (builtins.elem "gomod2nix.toml" basicFiles))
      (assert' "basic: drops README.md" (! (builtins.elem "README.md" basicFiles)))
      (assert' "basic: drops VERSION" (! (builtins.elem "VERSION" basicFiles)))
      (assert' "basic: keeps cmd/example/main.go"
        (builtins.elem "main.go" basicCmdFiles))
      (assert' "extras: keeps VERSION" (builtins.elem "VERSION" withExtrasFiles))
      (assert' "extras: keeps doc/intro.md" (builtins.elem "intro.md" withExtrasDocFiles))
    ];
  }
  "touch $out"
```

**Step 2: Run the test, verify it fails**

```bash
just nix-build-tests-source-filter  # or directly:
nix-build pkgs/build-support/gomod2nix/source-filter-test.nix
```

Expected: failure with `error: attribute 'goSourceFilter' missing` (the helper doesn't exist yet).

If the helper file doesn't yet have a justfile recipe, run directly via `nix-build`.

**Step 3: Implement the helper**

`pkgs/build-support/gomod2nix/source-filter.nix`:

```nix
# Source-tree filter for the go-pkgs producer convention (RFC 0001).
# Returns a cleanSourceWith-filtered view of `src` that keeps only
# Go-relevant files plus caller-supplied `extras` regex patterns.
#
# Patterns are POSIX extended regex (builtins.match semantics), NOT
# globs. Examples: "^doc/.*" "^VERSION$" ".*\\.tmpl$".
#
# Implementation primitive: lib.sources.sourceByRegex (existing stdlib
# function). See lib/sources.nix in nixpkgs master.
{ lib }:
let
  defaultRegexes = [
    ".*\\.go$"
    "^go\\.mod$"
    "^go\\.sum$"
    "^gomod2nix\\.toml$"
  ];

  goSourceFilter =
    {
      src,
      extras ? [ ],
    }:
    lib.sources.sourceByRegex src (defaultRegexes ++ extras);

  goSourceFilterMiddleware = src: goSourceFilter { inherit src; };
in
{
  inherit goSourceFilter goSourceFilterMiddleware;
}
```

**Step 4: Re-export from `default.nix`**

Modify `pkgs/build-support/gomod2nix/default.nix`. In the `let` block (around line 80-85, near the other `import` lines), add:

```nix
  sourceFilter = import ./source-filter.nix { inherit lib; };
  inherit (sourceFilter) goSourceFilter goSourceFilterMiddleware;
```

In the trailing `in { inherit ...; }` block (line 920-931), add `goSourceFilter` and `goSourceFilterMiddleware` to the `inherit` list:

```nix
in
{
  inherit
    buildGoApplication
    buildGoRace
    buildGoCover
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    goSourceFilter
    goSourceFilterMiddleware
    hooks
    ;
}
```

**Step 5: Wire into the overlay**

Modify `overlays/amarbel-packages.nix:25-33`. The existing block:

```nix
inherit
  (final.callPackage ../pkgs/build-support/gomod2nix { })
  buildGoApplication
  buildGoRace
  buildGoCover
  mkGoEnv
  mkVendorEnv
  mkGoCacheEnv
  ;
```

Becomes:

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

**Step 6: Run the test, verify it passes**

```bash
nix-build pkgs/build-support/gomod2nix/source-filter-test.nix
```

Expected: build succeeds; `result` symlink points at an empty `runCommand` output (the assertion thunks evaluate to `null` and don't throw).

**Step 7: Quick sanity check via `nix eval`**

```bash
nix eval --raw --impure --expr '
  let pkgs = import ./. { }; in pkgs.lib.attrNames (
    builtins.readDir (pkgs.goSourceFilter {
      src = ./pkgs/build-support/gomod2nix;
    })
  )
' | tr "," "\n" | head -20
```

Expected: only Go-relevant filenames listed (no `.scd`, `.md`, etc.). The `default.nix` itself is `.nix` so it's also dropped — that's correct behavior; the fixture is the authoritative test.

**Step 8: Commit**

```bash
mcp__plugin_moxy_moxy__grit_add paths=[
  "pkgs/build-support/gomod2nix/source-filter.nix"
  "pkgs/build-support/gomod2nix/source-filter-test.nix"
  "pkgs/build-support/gomod2nix/default.nix"
  "overlays/amarbel-packages.nix"
]
mcp__plugin_moxy_moxy__grit_commit message="pkgs/build-support/gomod2nix: add goSourceFilter helper

Implements RFC 0001 § Source filtering. Backed by lib.sources.sourceByRegex
from nixpkgs stdlib; default keep-set is *.go + go.mod + go.sum +
gomod2nix.toml. Extras are POSIX extended-regex strings (no glob support
exists in nixpkgs lib, confirmed via lib/sources.nix master).

Includes goSourceFilterMiddleware as a 1-line src -> src wrapper for
future use with mkGoPkgs.middlewares pipeline (deferred per FDR-0004's
exploring status).

Test fixture at source-filter-test.nix asserts default keep-set and
extras semantics.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 10: scdoc man page `goSourceFilter.7.scd`

**Files:**
- Create: `pkgs/build-support/gomod2nix/goSourceFilter.7.scd`

**Step 1: Verify the gomod2nix-man derivation auto-discovers `*.7.scd`**

Read `overlays/amarbel-packages.nix:43-67` — confirms the derivation iterates `for f in $src/*.7.scd; do ... done`. No further wiring needed; just create the file.

**Step 2: Write the man page**

`pkgs/build-support/gomod2nix/goSourceFilter.7.scd`:

```
goSourceFilter(7) ["amarbel-llc/nixpkgs"]

# NAME

goSourceFilter - Go source-tree filter for the go-pkgs producer convention

# SYNOPSIS

```
packages.${system}.go-pkgs = pkgs.goSourceFilter {
  src = ./.;
  extras = [ "^doc/.*" "^VERSION$" ];
};
```

# DESCRIPTION

*pkgs.goSourceFilter* produces a *cleanSourceWith*-filtered view of
a Go project's source tree. The output is suitable for use as a
*packages.${system}.go-pkgs* flake output (per RFC 0001) and as
*src* to *buildGoApplication* via the *goFlakeInputs* bridge.

The default keep-set is the minimum required by the Go build system
plus the *gomod2nix.toml* lockfile:

- *\*.go* — any Go source file
- *go.mod*
- *go.sum*
- *gomod2nix.toml*

All other files are dropped. The *extras* argument adds additional
patterns; see *EXTRAS* below.

# ARGUMENTS

- *src* — a path or derivation containing the Go source tree.
- *extras* — list of POSIX extended-regex strings (default: empty)
  that augment the default keep-set. Patterns match the source-tree
  relative path of each file.

# EXTRAS

*extras* are passed to *lib.sources.sourceByRegex* internally. They
are *regex* strings, not glob patterns. nixpkgs stdlib does not ship
glob matching.

Examples:

```
# Keep the doc/ subtree
extras = [ "^doc/.*" ];

# Keep a single root file
extras = [ "^VERSION$" ];

# Keep all *.tmpl files
extras = [ ".*\\.tmpl$" ];

# Combine
extras = [ "^doc/.*" "^VERSION$" ".*\\.tmpl$" ];
```

# STORE PATH NAMING

*goSourceFilter* preserves *src.name*. The resulting store path is
named identically to *src*. Producers who want a more diagnostic
name can wrap the output:

```
lib.cleanSourceWith {
  name = "${src.name}-go-source";
  src = pkgs.goSourceFilter { inherit src; };
}
```

# MIDDLEWARE WRAPPER

*pkgs.goSourceFilterMiddleware* is a 1-line *src -> src* wrapper
around *goSourceFilter*. It exists for composition with the (deferred)
*mkGoPkgs.middlewares* pipeline:

```
packages.${system}.go-pkgs = pkgs.mkGoPkgs {
  src = self;
  middlewares = [
    pkgs.goSourceFilterMiddleware
    pkgs.dagnabitExportMiddleware  # example future middleware
  ];
};
```

# LIMITATIONS

- *extras* uses regex, not globs (no nixpkgs stdlib equivalent of
  *fnmatch*).
- Store-path naming preserves *src.name* by default; rename via
  *cleanSourceWith* if desired.
- *goSourceFilter* operates on *src* as a single tree. Multi-module
  repos with separate Go modules in different subdirectories need
  per-module filter invocations.

# SEE ALSO

*gomod2nix*(7), *lib.sources.sourceByRegex*,
*docs/rfcs/0001-flake-input-go_mod.md*.
```

**Step 3: Verify the man page builds**

```bash
nix build .#gomod2nix-man
ls result/share/man/man7/ | grep goSourceFilter
```

Expected: `goSourceFilter.7` present in the output.

**Step 4: Commit**

```bash
mcp__plugin_moxy_moxy__grit_add paths=["pkgs/build-support/gomod2nix/goSourceFilter.7.scd"]
mcp__plugin_moxy_moxy__grit_commit message="pkgs/build-support/gomod2nix: scdoc(7) man page for goSourceFilter

Picked up automatically by the gomod2nix-man derivation's *.7.scd glob
in overlays/amarbel-packages.nix.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 11: Thin FDR-0003

**Files:**
- Modify: `docs/features/0003-bridge-go-flake-inputs.md`

**Step 1: Insert RFC-pointer notice at top**

Immediately after the YAML frontmatter, before `# Bridge Go module deps from flake inputs`, add:

```markdown
> **Status:** the normative interface specification for the bridge
> protocol now lives in [RFC 0001](../rfcs/0001-flake-input-go_mod.md).
> This FDR is preserved for journey context, problem-statement
> framing, and the POC findings from commit f99a3ff43278. For the
> authoritative MUST/SHOULD/MAY contract on `goFlakeInputs`,
> `mkGoEnv` parity, and multi-producer closures, see the RFC.
```

**Step 2: Remove the normative `## Interface` and `## Multi-producer closures` sections**

Replace each section's body with a one-line pointer:

```markdown
## Interface

See [RFC 0001 § Consumer interface](../rfcs/0001-flake-input-go_mod.md#consumer-interface-goflakeinputs).

## Multi-producer closures: `follows` + passthru inheritance

See [RFC 0001 § Multi-producer closures](../rfcs/0001-flake-input-go_mod.md#multi-producer-closures-follows--passthru-inheritance).
```

Keep:
- `## Problem Statement`
- `## Examples` (the migration before/after — journey-flavored)
- `## POC findings` (entirely)
- `## Limitations` (replace body with pointer to RFC; keep POC-specific limitations inline)
- `## More Information`

**Step 3: Commit**

```bash
mcp__plugin_moxy_moxy__grit_add paths=["docs/features/0003-bridge-go-flake-inputs.md"]
mcp__plugin_moxy_moxy__grit_commit message="docs/features/0003: thin to journey-only; RFC 0001 owns normative spec

Replaces \`## Interface\` and \`## Multi-producer closures\` bodies with
pointers to RFC 0001. Keeps problem statement, POC findings, migration
example, and tracking links.

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 12: Thin FDR-0004 and close #39 / #40

**Files:**
- Modify: `docs/features/0004-go-pkgs-producer-convention.md`

**Step 1: Insert RFC-pointer notice at top**

Same shape as FDR-0003:

```markdown
> **Status:** the normative interface specification for the producer
> convention now lives in [RFC 0001](../rfcs/0001-flake-input-go_mod.md).
> This FDR is preserved for journey context and problem-statement
> framing. For the authoritative MUST/SHOULD/MAY contract on
> `packages.${system}.go-pkgs`, `mkGoPkgs`, and `goSourceFilter`,
> see the RFC.
```

**Step 2: Remove the normative `## Interface` body**

Replace with:

```markdown
## Interface

See [RFC 0001 § Producer interface](../rfcs/0001-flake-input-go_mod.md#producer-interface-packagessystemgo-pkgs-and-mkgopkgs)
and [RFC 0001 § Source filtering](../rfcs/0001-flake-input-go_mod.md#source-filtering-gosourcefilter).
```

Keep:
- `## Problem Statement`
- `## Examples` (the per-producer-shape examples — journey-flavored)
- `## Limitations`
- `## More Information`

**Step 3: Commit with Closes annotations**

```bash
mcp__plugin_moxy_moxy__grit_add paths=["docs/features/0004-go-pkgs-producer-convention.md"]
mcp__plugin_moxy_moxy__grit_commit message="docs/features/0004: thin to journey-only; RFC 0001 owns normative spec

Replaces \`## Interface\` body with pointers to RFC 0001's producer
interface and source-filtering sections. Keeps problem statement,
examples, and tracking links.

Closes #39
Closes #40

:clown: [Clown](https://github.com/amarbel-llc/clown)"
```

---

## Task 13: Final verification and merge

**Step 1: Verify the full RFC reads coherently**

Read `docs/rfcs/0001-flake-input-go_mod.md` end-to-end. Check that:

- All cross-references between sections resolve (anchor names align with section headings)
- The two thinned FDRs' pointer links target real anchors in the RFC
- Examples are consistent across sections
- No section is empty / placeholder

If anything looks off, fix in-place and amend the relevant commit (or add a fixup commit).

**Step 2: Verify all changed files appear in git status**

```bash
mcp__plugin_moxy_moxy__grit_status
```

Expected: clean working tree (all commits already made).

**Step 3: Verify recent commit log**

```bash
mcp__plugin_moxy_moxy__grit_log oneline=true max_count=15
```

Expected sequence (newest first):
- `docs/features/0004: thin to journey-only ... Closes #39 / #40`
- `docs/features/0003: thin to journey-only ...`
- `pkgs/build-support/gomod2nix: scdoc(7) man page for goSourceFilter`
- `pkgs/build-support/gomod2nix: add goSourceFilter helper`
- (RFC body commits, Tasks 2-8)
- `docs/rfcs: scaffold RFC 0001 (flake-input-go_mod protocol)`
- `docs/plans: design for flake-input-go_mod RFC + goSourceFilter`
- `CLAUDE.md: document amarbel-llc/nixpkgs as explicit get-hubbed target`

**Step 4: Merge via spinclass**

```
mcp__plugin_spinclass_spinclass__merge-this-session git_sync=true
```

The pre-merge hook runs `just` (build + test + bats + analyzers — the full CI lane). If it fails, investigate from the hook output; do not work around it. **Do not** redundantly run `just` before this step — the merge hook is the CI lane.

A non-error return means the merge succeeded, all commits landed on `master`, GitHub auto-closes #39 and #40, and the worktree session can continue accumulating the next piece of work.

---

## Notes for the implementing agent

- **Per-task subagents**: dispatch a fresh subagent for each task per `eng:subagent-driven-development`. Pass each task's "Files" + "Step N" sections as the subagent's prompt; the subagent does NOT need this whole plan.
- **Code review between tasks**: after Task 9 (helper implementation) and after Task 13 (final verification), invoke `eng:code-reviewer` on the diff for a sanity check before moving forward.
- **No new branches**: this worktree's branch is `sharp-cedar`; per CLAUDE.md the spinclass session reuses branches across many work cycles. Do NOT `git checkout -b` anything.
- **Do not call EnterWorktree / ExitWorktree**: spinclass owns worktree lifecycle.
- **If the merge hook fails**: investigate, fix, commit a follow-up, re-invoke `merge-this-session`. Do not skip the hook.
