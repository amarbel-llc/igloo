# goFlakeInputs Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use eng:subagent-driven-development to implement this plan task-by-task.

**Goal:** Add a `goFlakeInputs` argument to `buildGoApplication` and
`mkGoEnv` that lets callers source Go module dependencies from nix flake
inputs, eliminating the lockstep-drift class (go.mod pseudo-version +
gomod2nix.toml hash + flake.lock rev drifting out of sync).

**Architecture:** Eval-time substitution. When `goFlakeInputs` is
non-empty, the builder constructs two intermediate derivations
(`mergedGoMod`, `mergedGomod2nixToml`) that produce the merged
go.mod / gomod2nix.toml that `mkVendorEnv` then consumes. The existing
`localReplaceCommands` block is adjusted to handle absolute (nix-store)
replace targets in addition to relative paths. All work happens before
the final derivation is constructed, so `buildGoRace` / `buildGoCover`
`overrideAttrs` wrappers compose by construction.

**Tech Stack:** Nix (flake-style), `pkgs/build-support/gomod2nix/`,
gomod2nix CLI, Go 1.26.

**Rollback:** `goFlakeInputs` defaults to `{}`. When unset, every code
path is bit-identical to today's `buildGoApplication`. Consumer-level
revert is a single-call-site edit (remove `goFlakeInputs`, restore the
`require` / `replace` / `[mod.…]` entries the bridge had been
suppressing). No migration commits to undo.

**Background to read first:**
- Design: `docs/plans/2026-05-23-goflake-inputs-design.md`
- FDR: `docs/features/0003-bridge-go-flake-inputs.md`
- POC: `zz-pocs/goflake-poc/README.md` + commit f99a3ff43278
- Tracking issue: [amarbel-llc/nixpkgs#32](https://github.com/amarbel-llc/nixpkgs/issues/32)
- Existing builder: `pkgs/build-support/gomod2nix/default.nix`
  (focus: `mkVendorEnv`, `buildGoApplication`, `mkGoEnv`,
  `localReplaceCommands` at lines 198-205)

---

## Task 1: Add `goFlakeInputs` normalizer

**Promotion criteria:** N/A (new code path).

**Files:**
- Modify: `pkgs/build-support/gomod2nix/default.nix` (top of `let`
  block, before `mkVendorEnv` definition)

**Background:** `goFlakeInputs` values can be either a bare derivation
(shorthand) or an attrset `{ src, subPath }`. The rest of the code
assumes the attrset form. A normalizer at the entry point handles this
once.

**Step 1: Write a nix eval test**

Add to `zz-pocs/goflake-poc/` a new file `normalizer-test.nix`:

```nix
# Test: normalizeFlakeInput accepts both shapes
{ pkgs }:
let
  inherit (pkgs.callPackage ../../pkgs/build-support/gomod2nix/internals.nix { })
    normalizeFlakeInput;
in {
  bareDrv = normalizeFlakeInput pkgs.hello;
  # Expected: { src = pkgs.hello; subPath = ""; }

  attrsForm = normalizeFlakeInput { src = pkgs.hello; subPath = "go"; };
  # Expected: { src = pkgs.hello; subPath = "go"; }
}
```

**Step 2: Run it and watch it fail**

Run: `nix eval --impure --expr 'import ./zz-pocs/goflake-poc/normalizer-test.nix { pkgs = import <nixpkgs> {}; }'`

Expected: FAIL (no `internals.nix`, no `normalizeFlakeInput`)

**Step 3: Implement the normalizer**

Create `pkgs/build-support/gomod2nix/internals.nix`:

```nix
{ lib }:
{
  # Normalize a goFlakeInputs value into { src, subPath } form.
  # Accepts:
  #   - a derivation or path (subPath defaults to "")
  #   - an attrset already in { src, subPath } form
  normalizeFlakeInput = value:
    if value ? src
    then { inherit (value) src; subPath = value.subPath or ""; }
    else { src = value; subPath = ""; };
}
```

In `pkgs/build-support/gomod2nix/default.nix`, expose this in the let
block:

```nix
let
  internals = import ./internals.nix { inherit lib; };
  inherit (internals) normalizeFlakeInput;
  # ... rest of let block
```

**Step 4: Run the test and watch it pass**

Run: `nix eval --impure --expr '...'` (same as Step 2)

Expected: PASS (returns two attrs both with `src` and `subPath`)

**Step 5: Commit**

```bash
git add pkgs/build-support/gomod2nix/internals.nix \
        pkgs/build-support/gomod2nix/default.nix \
        zz-pocs/goflake-poc/normalizer-test.nix
git commit -m "gomod2nix: add goFlakeInputs value normalizer

Splits the value-shape handling out of the eventual call sites.
Accepts both bare derivations (shorthand) and { src, subPath }
attrsets. First step toward goFlakeInputs (amarbel-llc/nixpkgs#32)."
```

---

## Task 2: Add `mergedGoMod` derivation

**Promotion criteria:** N/A (new code path).

**Files:**
- Modify: `pkgs/build-support/gomod2nix/internals.nix` (add merge fn)
- Modify: `pkgs/build-support/gomod2nix/default.nix` (use it in let)

**Background:** When `goFlakeInputs` is non-empty, we need a `go.mod`
that includes synthetic `require` and `replace` lines for each flake
input. Produce this as an intermediate derivation that runs `go mod
edit` against the consumer's go.mod.

**Step 1: Write a build test**

Add to `zz-pocs/goflake-poc/`: `merged-go-mod-test.nix`:

```nix
{ pkgs, hello ? pkgs.hello }:
let
  inherit (pkgs.callPackage ../../pkgs/build-support/gomod2nix/internals.nix { })
    mkMergedGoMod;
  consumerGoMod = pkgs.writeText "go.mod" ''
    module github.com/test/consumer

    go 1.26
  '';
in mkMergedGoMod {
  inherit consumerGoMod;
  go = pkgs.go;
  goFlakeInputs = {
    "github.com/example/lib" = { src = hello; subPath = ""; };
  };
}
```

**Step 2: Run it and watch it fail**

Run: `nix build --impure --expr 'import ./zz-pocs/goflake-poc/merged-go-mod-test.nix { pkgs = import <nixpkgs> {}; }' -o result-test`

Expected: FAIL (`mkMergedGoMod` not defined)

**Step 3: Implement `mkMergedGoMod`**

Add to `pkgs/build-support/gomod2nix/internals.nix`:

```nix
{ lib, runCommand ? null }:
let
  sentinelPseudoVersion = "v0.0.0-00010101000000-000000000000";
in
{
  inherit sentinelPseudoVersion;

  normalizeFlakeInput = value: # ... (from Task 1)

  # Build a go.mod that includes synthetic require + replace lines for
  # each entry in goFlakeInputs. Pure-eval derivation, no network.
  mkMergedGoMod = { consumerGoMod, go, goFlakeInputs, runCommand }:
    runCommand "merged-go.mod" {
      buildInputs = [ go ];
    } ''
      cp ${consumerGoMod} ./go.mod
      chmod +w ./go.mod
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (modPath: rawValue:
        let v = (import ./internals.nix { inherit lib; runCommand = null; }).normalizeFlakeInput rawValue;
            target = "${v.src}${lib.optionalString (v.subPath != "") "/${v.subPath}"}";
        in ''
          go mod edit -require=${modPath}@${sentinelPseudoVersion}
          go mod edit -replace=${modPath}=${target}
        ''
      ) goFlakeInputs)}
      cp ./go.mod $out
    '';
}
```

Note: the `runCommand` is passed at the call site since `internals.nix`
shouldn't take stdenv as input directly. Adjust the signature so the
top-level `default.nix` provides it.

**Step 4: Run the test and watch it pass**

Run: same as Step 2.

Expected: PASS. Inspect `result-test`:

```bash
cat result-test
```

Should contain:
- `module github.com/test/consumer`
- `require github.com/example/lib v0.0.0-00010101000000-000000000000`
- `replace github.com/example/lib => /nix/store/...-hello`

**Step 5: Commit**

```bash
git add pkgs/build-support/gomod2nix/internals.nix \
        pkgs/build-support/gomod2nix/default.nix \
        zz-pocs/goflake-poc/merged-go-mod-test.nix
git commit -m "gomod2nix: add mkMergedGoMod derivation

Produces a merged go.mod with synthetic require + replace lines for
each goFlakeInputs entry. Runs go mod edit inside a runCommand at
eval time; no network, no FOD. Sentinel pseudo-version is the
minimum syntactically-valid form per semver.Canonical (verified by
the POC at f99a3ff43278)."
```

---

## Task 3: Add `mergedGomod2nixToml` calc (nix-level merge)

**Promotion criteria:** N/A.

**Files:**
- Modify: `pkgs/build-support/gomod2nix/internals.nix` (add merge fn)

**Background:** Union the consumer's `gomod2nix.toml` with each flake
input's `gomod2nix.toml`. On conflict (same Go module path appears in
both), consumer wins (per Q3). Pure nix; no shell.

**Step 1: Write a nix eval test**

Add to `zz-pocs/goflake-poc/`: `merged-toml-test.nix`:

```nix
{ pkgs }:
let
  inherit (pkgs.callPackage ../../pkgs/build-support/gomod2nix/internals.nix { })
    mergeGomod2nixTomls;
in mergeGomod2nixTomls {
  consumer = {
    schema = 3;
    mod = {
      "github.com/example/shared" = { version = "v1.0.0"; hash = "consumer-hash"; };
      "github.com/example/only-in-consumer" = { version = "v2.0.0"; hash = "c"; };
    };
  };
  flakeInputs = [
    {
      schema = 3;
      mod = {
        "github.com/example/shared" = { version = "v0.9.0"; hash = "flake-hash"; };
        "github.com/example/only-in-flake" = { version = "v3.0.0"; hash = "f"; };
      };
    }
  ];
}
```

Expected output: an attrset with `schema = 3` and `mod` containing all
three modules; `github.com/example/shared` resolves to the consumer's
version/hash (consumer wins).

**Step 2: Run it and watch it fail**

Run: `nix eval --impure --json --expr 'import ./zz-pocs/goflake-poc/merged-toml-test.nix { pkgs = import <nixpkgs> {}; }'`

Expected: FAIL (`mergeGomod2nixTomls` undefined)

**Step 3: Implement**

Add to `internals.nix`:

```nix
mergeGomod2nixTomls = { consumer, flakeInputs }:
  let
    # Consumer's mod entries take precedence over flake-input entries.
    # foldl' starts with all flake-input entries unioned, then layers
    # consumer's on top.
    flakeInputMerged = lib.foldl' (acc: t: (t.mod or {}) // acc) {} flakeInputs;
  in {
    schema = consumer.schema or 3;
    mod = flakeInputMerged // (consumer.mod or {});
  };
```

**Step 4: Run the test and watch it pass**

Run: same as Step 2.

Expected: PASS. Inspect output:

```json
{
  "schema": 3,
  "mod": {
    "github.com/example/shared": { "version": "v1.0.0", "hash": "consumer-hash" },
    "github.com/example/only-in-consumer": { "version": "v2.0.0", "hash": "c" },
    "github.com/example/only-in-flake": { "version": "v3.0.0", "hash": "f" }
  }
}
```

Confirm `shared` resolves to `consumer-hash`, not `flake-hash`.

**Step 5: Commit**

```bash
git add pkgs/build-support/gomod2nix/internals.nix \
        zz-pocs/goflake-poc/merged-toml-test.nix
git commit -m "gomod2nix: add mergeGomod2nixTomls

Unions the consumer's gomod2nix.toml mod entries with each flake
input's. Consumer wins on conflict (decided as Q3 in the design
doc). Pure nix-eval merge, no shell."
```

---

## Task 4: Adjust `localReplaceCommands` for absolute paths

**Promotion criteria:** Existing local-replace behavior preserved (organic
relative-path replaces still work after change).

**Files:**
- Modify: `pkgs/build-support/gomod2nix/default.nix:198-205`

**Background:** When `goFlakeInputs` injects synthetic replaces, the
replace target in the merged go.mod is an absolute `/nix/store/...`
path. The existing code at lines 198-205 prefixes `pwd` unconditionally:
`ln -s ${pwd + "/${value.path}"} vendor/${name}`. This breaks for
absolute paths. Detect them and skip prefixing.

**Step 1: Write a regression test for organic replaces**

In `zz-pocs/goflake-poc/`, ensure the original buildGoModule phase-2
target still works:

```bash
just nix-build
```

Expected: PASS (`FLAKE_INPUT_OK_v1` printed). Captures the baseline
before changing `localReplaceCommands`.

**Step 2: Write the new behavior test**

Update `zz-pocs/goflake-poc/default-via-gomod2nix.nix` to use a
hypothetical `goFlakeInputs` (it won't work yet — we wire it up in Task
5, but we can dry-run the line 204 logic in isolation by passing a
hand-crafted goMod attrset).

Actually defer this: the wired-up test goes in Task 5. For this task,
only the regression matters.

**Step 3: Modify lines 198-205**

Replace:

```nix
mkdir -p $(dirname vendor/${name})
ln -s ${pwd + "/${value.path}"} vendor/${name}
```

With:

```nix
mkdir -p $(dirname vendor/${name})
ln -s ${
  if lib.hasPrefix "/" value.path
  then value.path                  # absolute /nix/store path (from goFlakeInputs)
  else toString (pwd + "/${value.path}")  # organic relative path; legacy behavior
} vendor/${name}
```

Make sure `lib.hasPrefix` is in scope (it's available via the existing
`lib` binding at the top of the file — verify in the let block).

**Step 4: Run the regression test**

Run: `just nix-build` from `zz-pocs/goflake-poc/`.

Expected: PASS — the buildGoModule path still works (it doesn't use
gomod2nix's localReplaceCommands; this just confirms nothing else
broke). Also run `nix flake check` against `pkgs/by-name` if there's any
existing gomod2nix consumer in the repo (`gomod2nix` CLI itself is one
— `nix build .#gomod2nix` should pass).

Run: `nix build .#gomod2nix`

Expected: PASS (the CLI uses buildGoApplication with organic replaces;
if our change broke organic replaces, this would fail).

**Step 5: Commit**

```bash
git add pkgs/build-support/gomod2nix/default.nix
git commit -m "gomod2nix: handle absolute paths in localReplaceCommands

Existing logic at lines 198-205 unconditionally prefixed pwd to the
replace path. When goFlakeInputs injects synthetic replaces in a
later commit, the targets will be absolute /nix/store paths and
must not be re-prefixed. Detect absolute paths and skip prefixing;
relative paths keep their current behavior."
```

---

## Task 5: Wire `goFlakeInputs` into `buildGoApplication`

**Promotion criteria:** Phase 3 of zz-pocs/goflake-poc switches from
FAIL → PASS.

**Files:**
- Modify: `pkgs/build-support/gomod2nix/default.nix` (`buildGoApplication`
  function args + let block)
- Modify: `zz-pocs/goflake-poc/default-via-gomod2nix.nix` (use new arg)
- Modify: `zz-pocs/goflake-poc/flake.nix` (verify input still wired)

**Background:** Wire `mkMergedGoMod` + `mergeGomod2nixTomls` into the
buildGoApplication call site. When `goFlakeInputs` is empty (default),
fall through to today's behavior.

**Step 1: Update the POC's phase-3 derivation**

Edit `zz-pocs/goflake-poc/default-via-gomod2nix.nix`:

```nix
{ buildGoApplication, pocLibSrc }:

buildGoApplication {
  pname = "goflake-poc-via-gomod2nix";
  version = "0.1.0";
  src = ./.;
  pwd = ./.;
  modules = ./gomod2nix.toml;
  subPackages = [ "." ];

  goFlakeInputs = {
    "github.com/poc/lib" = pocLibSrc;
  };
}
```

(Remove the preBuild symlink trick — `goFlakeInputs` replaces it.)

Also update `zz-pocs/goflake-poc/go.mod` to remove the manual
`require` + `replace` (since `goFlakeInputs` now injects them):

```
module github.com/amarbel-llc/goflake-poc

go 1.23
```

**Step 2: Run it and watch it fail**

Run: `just nix-build-via-gomod2nix` from `zz-pocs/goflake-poc/`.

Expected: FAIL — `goFlakeInputs` not recognized as a buildGoApplication
arg.

**Step 3: Add `goFlakeInputs` to `buildGoApplication`**

In `pkgs/build-support/gomod2nix/default.nix`, around line 515:

```nix
buildGoApplication =
  {
    modules ? pwd + "/gomod2nix.toml",
    src ? pwd,
    pwd ? null,
    goFlakeInputs ? { },   # NEW: { "<go-module-path>" = derivation-or-{src,subPath}; }
    nativeBuildInputs ? [ ],
    # ... rest of args
    ...
  }@attrs:
  let
    # Normalize goFlakeInputs into a canonical attrset.
    normalizedFlakeInputs = lib.mapAttrs (_: normalizeFlakeInput) goFlakeInputs;

    # When goFlakeInputs is non-empty, build a merged go.mod and merged
    # gomod2nix.toml; otherwise, fall through to legacy behavior.
    hasFlakeInputs = normalizedFlakeInputs != { };

    consumerGoModPath = "${toString pwd}/go.mod";
    consumerGoModExists = pwd != null && pathExists consumerGoModPath;

    mergedGoModFile =
      if hasFlakeInputs && consumerGoModExists then
        mkMergedGoMod {
          consumerGoMod = consumerGoModPath;
          inherit goFlakeInputs;
          go = selectGo attrs goModForVersion;
          inherit runCommand;
        }
      else
        consumerGoModPath;

    goMod = if mergedGoModFile != null && pathExists mergedGoModFile
            then parseGoMod (readFile mergedGoModFile)
            else null;

    modulesStruct =
      let
        consumerToml = if modules == null then { } else fromTOML (readFile modules);
        flakeInputTomls = lib.mapAttrsToList (_: v:
          let path = "${v.src}${lib.optionalString (v.subPath != "") "/${v.subPath}"}/gomod2nix.toml";
          in if pathExists path then fromTOML (readFile path) else { mod = { }; }
        ) normalizedFlakeInputs;
      in
      if hasFlakeInputs
      then mergeGomod2nixTomls { consumer = consumerToml; flakeInputs = flakeInputTomls; }
      else consumerToml;

    # ... existing let block continues
```

**Step 4: Run the POC test**

Run: `just nix-build-via-gomod2nix` from `zz-pocs/goflake-poc/`.

Expected: PASS — `FLAKE_INPUT_OK_v1` prints from the binary.

If it fails, check:
- `nix log` for the failing derivation
- Whether `mergedGoMod` is being produced correctly (`nix build` the
  intermediate by exposing it as a passthru attr)
- Whether the localReplaceCommands change from Task 4 is actually
  detecting the absolute path

**Step 5: Commit**

```bash
git add pkgs/build-support/gomod2nix/default.nix \
        zz-pocs/goflake-poc/default-via-gomod2nix.nix \
        zz-pocs/goflake-poc/go.mod \
        zz-pocs/goflake-poc/gomod2nix.toml
git commit -m "gomod2nix: wire goFlakeInputs into buildGoApplication

When goFlakeInputs is non-empty, the builder constructs a merged
go.mod (via mkMergedGoMod) and a merged gomod2nix.toml (via
mergeGomod2nixTomls) before passing them to mkVendorEnv. When
empty (default), behavior is bit-identical to before.

Validates against zz-pocs/goflake-poc/: phase 3 (the
buildGoApplication variant that previously FAILed on eval-time path
import) now PASSes. Closes amarbel-llc/nixpkgs#32... wait, don't close yet
— mkGoEnv parity still pending.

Refs amarbel-llc/nixpkgs#32."
```

---

## Task 6: Mirror `goFlakeInputs` in `mkGoEnv`

**Promotion criteria:** Devshell parity — `nix develop` resolves
`goFlakeInputs` entries identically to `nix build`.

**Files:**
- Modify: `pkgs/build-support/gomod2nix/default.nix` (`mkGoEnv` function)

**Background:** Per FDR-0003's mandatory parities, mkGoEnv must accept
and process `goFlakeInputs`. Otherwise `nix develop` sees a different
module graph and re-introduces lockstep drift through the back door.

**Step 1: Write a parity test**

Add `zz-pocs/goflake-poc/devshell-parity-test.bash`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Build the binary via nix build
nix build .#via-gomod2nix
build_path=$(readlink -f result/bin/goflake-poc-via-gomod2nix)

# Enter the devshell, run `go env GOMOD` to confirm it sees the merged
# go.mod (or equivalent — TBD: what specific assertion proves parity?)
develop_view=$(nix develop --command go env GOMOD)

# At minimum, the devshell go.mod should reference the same flake
# input. Compare against the build's merged go.mod.
# ... (this needs design — see Step 3)
```

Defer the precise assertion to Step 3 — we'll know what to compare once
we've written the mkGoEnv merge logic.

**Step 2: Read the existing `mkGoEnv` definition**

Read `pkgs/build-support/gomod2nix/default.nix` from `mkGoEnv = ...`
through to its `}` close (search for `mkGoEnv` — definition is around
line 425+).

**Step 3: Add `goFlakeInputs` arg to `mkGoEnv`**

Apply the same merge logic from Task 5: accept `goFlakeInputs ? { }`,
build `mergedGoModFile` and `modulesStruct` the same way, pass them
through to whatever `mkGoEnv` uses internally (likely `mkVendorEnv`).

The `mkGoEnv` body change is structurally parallel to Task 5's
`buildGoApplication` change. Refactor the merge logic into a helper
that both call.

```nix
# In the top-level let:
let
  mkMergedView = { pwd, modules, goFlakeInputs, go, runCommand }:
    let normalizedFlakeInputs = lib.mapAttrs (_: normalizeFlakeInput) goFlakeInputs;
        hasFlakeInputs = normalizedFlakeInputs != { };
        # ... (same as Task 5's let block)
    in { inherit goMod modulesStruct; };
in
# both buildGoApplication and mkGoEnv use mkMergedView
```

**Step 4: Run the parity test**

Run `bash zz-pocs/goflake-poc/devshell-parity-test.bash`.

Expected: PASS — devshell sees the same merged go.mod / vendor view
as the nix-build does.

**Step 5: Commit**

```bash
git add pkgs/build-support/gomod2nix/default.nix \
        zz-pocs/goflake-poc/devshell-parity-test.bash
git commit -m "gomod2nix: mirror goFlakeInputs in mkGoEnv

Devshell parity: when a consumer's flake.nix builds packages via
goFlakeInputs, the same merge logic runs in mkGoEnv so nix develop
sees the same module graph. Without this, the lockstep-drift class
re-emerges through the devshell back door (organic go.mod in dev,
merged go.mod in build).

Refactors merge logic into mkMergedView so the two call sites can
share it."
```

---

## Task 7: Smoke test — `buildGoRace` composition

**Promotion criteria:** N/A (verification only).

**Files:**
- Add: `zz-pocs/goflake-poc/build-race-smoke-test.nix`

**Background:** Per Q5 / composition research, `buildGoRace`'s
`overrideAttrs` should leave the merged-derivation closure intact. Verify
with one test.

**Step 1: Write the test**

In `zz-pocs/goflake-poc/flake.nix`, add a third package:

```nix
packages.${system}.via-gomod2nix-race =
  pkgs.buildGoRace {
    base = self.packages.${system}.via-gomod2nix;
  };
```

**Step 2: Run it and watch the expected behavior**

Run: `nix build .#via-gomod2nix-race`

Expected: PASS. The binary is built with `-race`, and the embedded
`Sentinel = "FLAKE_INPUT_OK_v1"` const still resolves (because it came
from `pocLibSrc` via `goFlakeInputs`, baked into the underlying
derivation).

Confirm: `./result/bin/goflake-poc-via-gomod2nix-race` prints
`FLAKE_INPUT_OK_v1`.

**Step 3: Commit**

```bash
git add zz-pocs/goflake-poc/flake.nix
git commit -m "goflake-poc: smoke test for buildGoRace composition

Wraps the goFlakeInputs-using derivation with buildGoRace. Confirms
the wrapper's overrideAttrs leaves the merged go.mod / vendor
closure intact (composition is structural per the design doc's
research)."
```

---

## Task 8: Smoke test — `overrideAttrs` preservation

**Promotion criteria:** N/A (verification only).

**Files:**
- Modify: `zz-pocs/goflake-poc/flake.nix` (add an inline override test)

**Background:** Per composition invariant 3 from the design doc:
`(buildGoApplication { goFlakeInputs = ...; }).overrideAttrs(_: {})`
should still have the merged go.mod / vendor entries.

**Step 1: Add the test**

In `zz-pocs/goflake-poc/flake.nix`:

```nix
packages.${system}.via-gomod2nix-overridden =
  self.packages.${system}.via-gomod2nix.overrideAttrs (_: {
    # No-op override; should not change anything material.
    NIX_DEBUG = "0";
  });
```

**Step 2: Run and verify**

Run: `nix build .#via-gomod2nix-overridden && ./result/bin/goflake-poc-via-gomod2nix`

Expected: PASS, `FLAKE_INPUT_OK_v1` prints.

**Step 3: Commit**

```bash
git add zz-pocs/goflake-poc/flake.nix
git commit -m "goflake-poc: smoke test for overrideAttrs preservation

Confirms a no-op overrideAttrs doesn't dislodge the merged-derivation
closure produced by goFlakeInputs. Composition invariant 3 from the
design doc."
```

---

## Task 9: Document `goFlakeInputs` in the man page

**Promotion criteria:** N/A (docs).

**Files:**
- Modify: `pkgs/build-support/gomod2nix/gomod2nix.7.scd`

**Background:** Add a section explaining the `goFlakeInputs` argument,
its shape, the sentinel pseudo-version it uses, and the limitations.

**Step 1: Read the current scd**

Read `pkgs/build-support/gomod2nix/gomod2nix.7.scd` end-to-end.

**Step 2: Add a `# GOFLAKEINPUTS` section**

Right after the `# GO VERSION SELECTION` section. Cover:

- What it accepts (`{ src, subPath }` or bare derivation)
- Effect on `go.mod` (synthetic require + replace)
- Effect on `gomod2nix.toml` (union with consumer; consumer wins)
- Limitations (source-only, no auto-removal of organic requires)
- Cross-link to FDR-0003

Use the same example shape as the FDR (madder → tap with subPath).

**Step 3: Build the man page**

Confirm the page still builds:

```bash
nix build .#nix-man  # or whatever attr builds it
```

Expected: PASS.

**Step 4: Commit**

```bash
git add pkgs/build-support/gomod2nix/gomod2nix.7.scd
git commit -m "gomod2nix(7): document goFlakeInputs argument

Adds GOFLAKEINPUTS section covering value shape, effects on
go.mod / gomod2nix.toml, and limitations. Cross-links to
docs/features/0003-bridge-go-flake-inputs.md."
```

---

## Task 10: Merge the session

**Promotion criteria:** All Tasks 1-9 done; CI lane (pre-merge `just`
hook) green.

**Files:** None (operational).

**Step 1: Confirm all task commits are on the branch**

Run: `git log --oneline master..HEAD`

Expected: ~9 commits, one per task.

**Step 2: Stage any untracked artifacts** (probably none — POC tests are
all under `zz-pocs/goflake-poc/`).

Run: `git status`

Expected: clean working tree.

**Step 3: Invoke merge-this-session**

Call `mcp__spinclass__merge-this-session` with `git_sync: true`.

The pre-merge hook runs `just` (= `check-changed` over `pkgs/by-name/`
+ overlay pins). Our changes touch `pkgs/build-support/gomod2nix/`,
which is the `gomod2nix` overlay attr — the hook should evaluate that.

Expected: 5/5 TAP checks PASS.

**Step 4: Comment on amarbel-llc/nixpkgs#32**

Post the merge commit ref and a summary of what landed. Leave the issue
open until madder→tap integration lands (separate session, separate
repo).

---

## Out-of-scope (followups)

- **`madder` → `tap` adoption.** Separate session in `amarbel-llc/madder`.
  Plan: drop `[mod.…tap…]` from `gomod2nix.toml`, drop the `require` /
  `replace` lines from `go.mod`, add `goFlakeInputs."github.com/amarbel-llc/tap/go"
  = { src = inputs.tap; subPath = "go"; }` to madder's
  `buildGoApplication` call. Verify build + race wrapper + devshell.
- **FOD-regen of merged gomod2nix.toml** (Q3 option 3). Flagged for
  when the union-with-consumer-wins rule starts losing.
- **Auto-injected `require` cleanup.** Today the caller can have a
  vestigial `require` line in their organic go.mod for a module that's
  now in `goFlakeInputs`. The `go mod edit -require` overwrites the
  pseudo-version, but the line stays. Acceptable for now; cleanup is a
  later ergonomics pass.

---

Plan complete and saved to `docs/plans/2026-05-23-goflake-inputs-implementation.md`. Ready to execute?
