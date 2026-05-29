# goFlakeInputs implementation design

**Date:** 2026-05-23
**Tracks:** [amarbel-llc/nixpkgs#32](https://github.com/amarbel-llc/nixpkgs/issues/32)
**FDR:** `docs/features/0003-bridge-go-flake-inputs.md`
**POC:** `zz-pocs/goflake-poc/` (commit f99a3ff43278)

## Scope

This doc covers *how* to implement `goFlakeInputs` in
`pkgs/build-support/gomod2nix/default.nix`. The rationale and user-facing
interface live in FDR-0003. The decisions captured here resolve the
five scoping questions from the POC walkthrough.

## Resolved design decisions

| # | Question | Decision |
|---|---|---|
| Q1 | Synthetic `require` line | Builder auto-injects via `go mod edit -require=<module>@<sentinel>` at eval time |
| Q2 | `replace` directive ownership | `goFlakeInputs` is the sole source; builder injects both `-require` and `-replace` |
| Q3 | Transitive deps of flake input | Union `<flake-input>/<subPath>/gomod2nix.toml` with the consumer's, consumer wins on conflict. Document explicitly. Flag FOD-regen as eventual replacement when the union rule starts losing. |
| Q4 | Value shape | `{ src = <derivation>; subPath = "<path>"; }` (subPath optional, defaults to `""`); plain derivation accepted as shorthand for `{ src = it; subPath = ""; }` |
| Q5 | `buildGoRace` / `buildGoCover` composition | Eval-time substitution composes by construction (see Composition invariants). One smoke test post-impl. |
| Q6 | First integration target | `amarbel-llc/madder` → `amarbel-llc/tap` (madder already requires `github.com/amarbel-llc/tap/go`; tap's Go module lives at `./go/`, exercising the subPath path) |

## Surface

```nix
buildGoApplication {
  pname = "madder";
  src = ./.;
  pwd = ./.;
  modules = ./gomod2nix.toml;

  goFlakeInputs = {
    # Attrset form (explicit; required when the Go module isn't at flake root)
    "github.com/amarbel-llc/tap/go" = {
      src = inputs.tap;
      subPath = "go";
    };

    # Shorthand: bare derivation when the Go module IS at flake root
    "github.com/amarbel-llc/dewey" = inputs.dewey;
  };
}
```

The same `goFlakeInputs` arg is accepted by `mkGoEnv` (devshell parity is
mandatory — see FDR-0003 §Limitations).

## Mechanism: eval-time substitution

Most `goFlakeInputs` processing happens inside `buildGoApplication`'s
top-level `let` block, *before* the derivation is constructed. No
`preBuild` shell phase, no FOD, no recursive nix. Three intermediate
nix-eval-time derivations chain together, plus a single `postPatch`
step that swaps the merged `go.mod` into the unpacked source tree at
build time (see *Build-time go.mod swap* below).

### 1. `mergedGoMod` derivation

Inputs:
- The consumer's `go.mod` (read from `pwd + "/go.mod"`)
- The `goFlakeInputs` attrset, normalized so each value is
  `{ src, subPath }`
- A sentinel pseudo-version constant:
  `v0.0.0-00010101000000-000000000000`

Body:
```bash
cp $consumerGoMod ./go.mod
${concatMapStringsSep "\n" (modPath: { src, subPath }: ''
  go mod edit -require=${modPath}@${sentinelPseudoVersion}
  go mod edit -replace=${modPath}=${src}${optionalString (subPath != "") "/${subPath}"}
'') normalizedGoFlakeInputs}
cp go.mod $out
```

Output: a single `go.mod` file in the store.

### 2. `mergedGomod2nixToml` derivation

Inputs:
- The consumer's `gomod2nix.toml` (from `modules`)
- For each `goFlakeInputs` entry, the flake input's
  `gomod2nix.toml` (read at `<src>/<subPath>/gomod2nix.toml`) if it
  exists

Body (nix-side, no shell):
```nix
mergedToml =
  let
    consumerToml = fromTOML (readFile modules);
    flakeInputTomls = mapAttrsToList (modPath: { src, subPath }:
      let path = "${src}${optionalString (subPath != "") "/${subPath}"}/gomod2nix.toml";
      in if pathExists path then fromTOML (readFile path) else { mod = {}; }
    ) normalizedGoFlakeInputs;
    # Consumer wins on conflict (per Q3)
    mergedMod = foldl' (acc: t: t.mod or {} // acc) (consumerToml.mod or {}) flakeInputTomls;
  in {
    schema = consumerToml.schema or 3;
    mod = mergedMod;
  };
```

A `mkVendorEnv`-shaped intermediate writes this to a toml file in the
store, consumed by `mkVendorEnv`'s existing logic.

### 3. `mkVendorEnv` invocation

Replace the current `goMod` and `modulesStruct` references at
`buildGoApplication`'s call site:
- `goMod` is parsed from `mergedGoMod`'s output instead of from `pwd +
  "/go.mod"`.
- `modulesStruct` is `mergedGomod2nixToml` instead of
  `fromTOML (readFile modules)`.

The existing `localReplaceCommands` block (lines 198-205) sees the
synthetic `replace` entries from the merged go.mod alongside the
organic ones. For synthetic entries, `pwd + "/${value.path}"` would
break — *but* the synthetic `replace` targets are absolute `/nix/store/...`
paths (we injected them as `<src>/<subPath>` from a derivation), not
relative paths. The current code's path concatenation logic must be
adjusted to detect "is this path absolute?" and skip the `pwd +`
prefixing in that case.

### Concrete change at lines 198-205

Before:
```nix
mkdir -p $(dirname vendor/${name})
ln -s ${pwd + "/${value.path}"} vendor/${name}
```

After:
```nix
mkdir -p $(dirname vendor/${name})
ln -s ${
  if hasPrefix "/" value.path
  then value.path                  # absolute /nix/store path; use as-is
  else pwd + "/${value.path}"      # organic relative path; legacy behavior
} vendor/${name}
```

### 4. Build-time `go.mod` swap (`postPatch`)

`mergedGoMod` flowing into `mkVendorEnv` is necessary but not
sufficient. The Task 5 implementation surfaced that `go build
-mod=vendor` also reads the **source-tree** `go.mod` for the module
declaration and the `replace` map; the unpacked source's organic
`go.mod` lacks the synthetic `require` / `replace` lines that
`goFlakeInputs` introduces. Without a swap, the build sees mismatched
vendor entries (which `mkVendorEnv` placed using the merged map) and a
source-tree `go.mod` that doesn't acknowledge them.

The fix is a one-line `postPatch` shell step on the main derivation:

```nix
postPatch = ''
  cp ${mergedGoModFile} go.mod
'';
```

This runs after `unpackPhase` and before `configurePhase` / `buildPhase`,
so the Go toolchain sees the merged `go.mod` for the rest of the build.
`postPatch` is chosen over `preBuild` deliberately (see *Composition
invariants* below).

## Composition invariants

From the buildGoRace/buildGoCover research:

1. **Build-time mutations of the source tree (the merged-`go.mod`
   swap) live in `postPatch`, not `preBuild`.** This avoids preBuild
   concatenation conflicts with `buildGoRace` / `buildGoCover`
   wrappers, which use `preBuild` for `buildFlagsArray+=` shell
   fragments. Everything else — the `mergedGoMod` /
   `mergedGomod2nixToml` derivations consumed by `mkVendorEnv` — stays
   in the `let` block as closures captured at construction time,
   immune to `overrideAttrs`.
2. **No new top-level attrs that the wrappers touch.** Surface
   `goFlakeInputs` as `passthru.goFlakeInputs` for debugging/inspection
   only.
3. **Post-impl smoke test:** `(buildGoApplication { goFlakeInputs = X;
   }).overrideAttrs(_: {})` should still have the synthetic vendor/
   entries. One-line check.

## Mandatory parities

- **`mkGoEnv`**: accept and process `goFlakeInputs` identically. Without
  this, `nix develop` and `nix build` see different module graphs —
  silently re-introduces the lockstep-drift class.
- **`buildGoRace` / `buildGoCover`**: no code change needed (composition
  is structural per above). Smoke test only.

## Rollback strategy

Required per brainstorming skill:

1. **Dual-architecture period.** `goFlakeInputs` is opt-in (defaults to
   `{ }`). When unset, `buildGoApplication` and `mkGoEnv` behave
   bit-identically to today. The two paths coexist forever; the new
   path is incremental.
2. **Promotion criteria.** The bridge has carried `madder → tap` (and at
   least one other consumer/producer pair) for one release cycle, and
   the `gomod2nix.toml` lockstep-drift class has empirically not
   reappeared via the bridge for any committed bump.
3. **Rollback procedure.** A consumer that hits an unexpected behavior
   removes the `goFlakeInputs` arg from its `buildGoApplication` call
   and adds back the `require` / `replace` lines + `gomod2nix.toml`
   entries for the affected modules. Single-call-site revert; no
   multi-commit rollback. The builder's behavior with `goFlakeInputs =
   { }` is unchanged from today.

The dual-architecture property is structural: the new code only fires
when `goFlakeInputs` is non-empty.

## Out of scope for this implementation

- **FOD-regen of merged `gomod2nix.toml`** (Q3 option 3). Flag as
  follow-up when the union-with-consumer-wins rule starts losing.
- **Auto-`require`-removal from `go.mod`.** Caller's existing organic
  requires stay; `goFlakeInputs` adds/overrides via `go mod edit`,
  doesn't remove anything.
- **Cross-flake `resolveGoPackages` (FDR-0001 Path B).** Unrelated
  workstream.
- **Pre-built or non-Go flake inputs.** `goFlakeInputs` values are
  source-tree derivations only.

## File-level change inventory

| File | Change |
|---|---|
| `pkgs/build-support/gomod2nix/default.nix` | Add `goFlakeInputs` arg to `buildGoApplication` and `mkGoEnv`. Add `mergedGoMod` / `mergedGomod2nixToml` intermediate derivations. Adjust `localReplaceCommands` (lines 198-205) to handle absolute-path replace targets. Wire `mergedGoMod` / `mergedGomod2nixToml` into the call site so `mkVendorEnv` reads merged data. |
| `pkgs/build-support/gomod2nix/gomod2nix.7.scd` | Document `goFlakeInputs` argument shape, example, sub-decisions table. |
| `zz-pocs/goflake-poc/` | Convert phase-3 to PASS state by adopting `goFlakeInputs`. POC stays as the canonical example/smoke test. |
| `<consumer flake.nix at amarbel-llc/madder>` | Adopt `goFlakeInputs` for the `github.com/amarbel-llc/tap/go` require. Drop the corresponding `[mod.…tap…]` entry from `gomod2nix.toml`. (Not in this repo — separate work in `amarbel-llc/madder`.) |

## Validation plan

After impl, before declaring done:

1. **Smoke test in POC.** `zz-pocs/goflake-poc/`'s phase-3 derivation
   should switch from FAIL → PASS by adopting `goFlakeInputs`.
2. **buildGoRace smoke test.** Wrap a `goFlakeInputs`-using derivation
   with `buildGoRace` and confirm it builds.
3. **`overrideAttrs` smoke test** (Composition invariant 3).
4. **mkGoEnv parity check.** `nix develop` inside a consumer adopting
   `goFlakeInputs` resolves `import "github.com/amarbel-llc/tap/go"` to
   the same store path that `nix build` uses.
5. **Madder → tap integration.** End-to-end: madder's go.mod loses its
   `tap` entry from `gomod2nix.toml`, gains `goFlakeInputs`; `nix build
   .#madder` succeeds; bumping `inputs.tap` in `flake.lock` changes
   the embedded version with no other edits.

## Open questions to surface during impl

- Exact location of intermediate derivations: separate file
  (`pkgs/build-support/gomod2nix/flake-inputs.nix`) or inline? Lean
  separate for testability.
- Does `mkVendorEnv` need any other call sites updated, or is reading
  `goMod` / `modulesStruct` the only contact surface? Verify during
  impl.
- Schema-version assumption: we read `gomod2nix.toml` `schema = 3`. If
  a flake input ships a different schema, what's the policy? Likely:
  refuse to merge with a clear error, document.
