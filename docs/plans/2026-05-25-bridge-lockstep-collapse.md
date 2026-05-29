---
date: 2026-05-25
status: proposed
tracks:
  - amarbel-llc/nixpkgs#37
  - amarbel-llc/nixpkgs#51
relates:
  - amarbel-llc/nixpkgs#41
  - amarbel-llc/nixpkgs#42
rfc: docs/rfcs/0001-flake-input-go_mod.md
---

# Design: collapse the consumer-side bridge lockstep

## Context

Three issues against the `flake-input-go_mod` protocol all describe
facets of the same structural problem:

- **#37** — `gomod2nix.toml` keeps carrying entries for bridged
  modules. The `gomod2nix generate` regen wrapper re-adds them on
  every run, and adopters delete them by hand. The bridge strips them
  at merge time, but only when the call site passes `goFlakeInputs`.
- **#51** — `go.mod` keeps carrying a `require <module> <pseudo-version>`
  line that the bridge marks vestigial. The pseudo-version is inert
  (the bridge issues a `go mod edit -require=...@<sentinel>` at build
  time), but adopters hand-bump it anyway and get confused when their
  bump silently has no effect.
- **#41** — when a consumer has multiple call sites
  (`buildGoApplication`, `mkGoEnv`, `buildGoRace`, etc.) and one
  forgets to thread `goFlakeInputs`, the build silently uses the
  stale `gomod2nix.toml` hashes + stale `go.mod` pseudo-version
  instead of the flake input's resolved source. The proposed lint
  catches this at flake-eval time.

Each issue, taken in isolation, has a sensible-looking fix. Taken
together they reveal a single smell: **the bridge collapses the
three-place lockstep at merge time, but the two consumer-side pins
(`go.mod` require line and `gomod2nix.toml` mod entry) are still
maintained as if they were authoritative**. Both pins are *escape
hatches* — invisible at the happy path, load-bearing at the failure
path. #41's silent missing-thread bug exists *because* those escape
hatches still have valid-looking content for the bridge to fall
through to.

The right fix is structural: remove the escape hatches so missing
threading fails loudly instead of falling through to stale state. The
lint then becomes either a small ergonomics upgrade or unnecessary.

## Diagnosis

For a single bridged module `dep1`, the on-disk state today is:

| Location | Current state | What the bridge does at merge time |
|---|---|---|
| `go.mod` `require dep1 <pseudo>` | adopter-maintained; whatever pseudo-version is current | overridden via `go mod edit -require=dep1@<sentinel>` |
| `gomod2nix.toml` `[mod."dep1"]` | regen wrapper re-adds; adopter deletes | stripped via `bridgedKeys` in `mergeGomod2nixTomls` |
| `flake.lock` `inputs.dep1.rev` | nix flake update | source-of-truth — the bridge's `replace` points here |

The bridge does the right thing for any call site that passes
`goFlakeInputs`. It does nothing for a call site that doesn't.
Without `goFlakeInputs`:

- `go.mod`'s pseudo-version is taken literally; Go tries to fetch
  `dep1@v0.0.0-...` from the module proxy.
- `gomod2nix.toml`'s `[mod."dep1"]` entry tells `mkVendorEnv` to
  fetch the dep at the listed NAR hash.

Both succeed locally. The user observes `go test` works in the
devshell. They don't notice that the working code is a different
version than what `nix build` produces — until a bump.

If neither pin had valid content, the missing-thread call site
would fail loudly:

- `go.mod` with sentinel pseudo-version `v0.0.0-00010101000000-000000000000`
  → Go's module proxy returns 404 for that pseudo-version → loud
  error.
- `gomod2nix.toml` without `[mod."dep1"]` → `mkVendorEnv` has no
  entry to vendor → `vendor/modules.txt` missing `dep1` → `go build
  -mod=vendor` errors with "missing module in vendor/".

So: **make both pins always-invalid-for-bridged-modules**. The
bridge's bridged-keys context is the only thing that turns the
invalid pins into a working build.

## Proposal

Two convention promotions plus two enforcement mechanisms.

### 1. `gomod2nix.toml`: SHOULD NOT → MUST NOT for bridged entries

RFC 0001 § Consumer interface currently says:

> The consumer's `gomod2nix.toml` SHOULD NOT carry entries for modules
> declared in `goFlakeInputs` — leaving them in is cosmetically untidy
> but functionally harmless (the bridge strips them at merge time).

Promote to **MUST NOT**, enforced by:

- **mkGoEnv's `go` wrapper** post-processes `gomod2nix.toml` after
  every `gomod2nix generate` run (the wrapper already exists at
  `default.nix:541-555`; today it just unconditionally regenerates).
  The wrapper has eval-time access to `goFlakeInputs`, so it knows
  the bridged-keys list. After regen, strip those keys from the
  emitted toml. Adopters can no longer drift between `gomod2nix
  generate` runs.
- **Bridge eval-time check**: when a call site passes `goFlakeInputs`
  and the consumer's `gomod2nix.toml` STILL contains a bridged
  module path, emit an eval-time error explaining how to remove the
  drift (or hand off to the wrapper's auto-strip if invoked through
  the devshell). Migration grace period: warning for one release
  cycle, then error.

### 2. `go.mod`: sentinel-only for bridged modules

RFC 0001 already documents the sentinel (`v0.0.0-00010101000000-000000000000`).
Promote to a requirement: the `require` line for a bridged module
**MUST** carry the sentinel pseudo-version. Enforced by:

- **Bridge eval-time check**: when a `goFlakeInputs` entry points at
  module `dep1` and the consumer's `go.mod`'s `require dep1 v0.X.Y`
  line carries anything other than the sentinel, emit an eval-time
  error. The user-facing fix is a single-token edit.
- **(Optional follow-up)** A `gomod2nix sync-flake-inputs` helper
  that rewrites bridged require lines to the sentinel. Decouples
  this work from #37 since the eval-time check is sufficient by
  itself.

### Outcome

A call site that forgets to thread `goFlakeInputs` now sees:

- `gomod2nix.toml` has no entry for the bridged module → vendor
  resolution fails loudly at build time.
- `go.mod` has the sentinel pseudo-version → Go can't fall through
  to the module proxy → fails loudly.

Both failures point at "you didn't thread `goFlakeInputs` to this
call site". The bug class #41 was designed to catch is now
**structurally impossible** to ship.

## What about #41?

The lint becomes optional:

- **Strictly unnecessary for correctness** — the structural fix
  above makes the missing-thread case a hard build failure, not a
  silent stale-pin.
- **Still useful for ergonomics** — catches the bug at
  `nix flake check` / flake-eval rather than at `nix build`. Cheaper
  signal; faster iteration loop for adopters who add a new call site
  and forget the threading.
- **Implementation simplifies** — once `gomod2nix.toml` MUST NOT
  carry bridged entries, the lint can read the on-disk toml + each
  call site's args and emit a precise list of "call sites missing
  `goFlakeInputs = <expected attrset>`".

Recommendation: ship #41 *after* this design lands. With the
structural fix in place, #41 reduces to a ~30-line check that runs
`rg` over `.nix` files and cross-references against the toml. If the
structural fix doesn't land, #41 still has value but is a workaround.

## Implementation outline

Concrete pieces this design enables, in dependency order:

1. **`internals.nix`**: add eval-time checks in `mkMergedView` that
   throw on first eval (no warning mode, no flag):
   - For each `goFlakeInputs` entry whose key appears in the
     consumer's `gomod2nix.toml` `[mod."<key>"]` table → throw with
     a "run `gomod2nix generate` in nix develop" hint.
   - For each `goFlakeInputs` entry: parse the consumer's go.mod
     require line; if the pseudo-version is not the sentinel →
     throw pointing at the sentinel constant.
   - Pseudocode:
     ```nix
     bridgedKeys = attrNames goFlakeInputs;
     drifted = filter (k: (consumerModulesStruct.mod or {}) ? ${k}) bridgedKeys;
     if drifted != [] then throw "bridge: gomod2nix.toml drift on ${...}" else ...
     ```

2. **`mkGoEnv` go-wrapper**: extend `goSyncWrapper` in `default.nix`
   to post-process `gomod2nix.toml` after every `gomod2nix generate`.
   Bridged keys are interpolated into the wrapper at flake-eval time
   (per resolved sub-decision 2). Implementation: a small Nix-built
   Go (or Python) helper that takes a list of module paths and
   removes matching `[mod."..."]` tables from a toml file in place.
   jq is awkward for toml; prefer a focused helper that ships as
   `pkgs.gomod2nixStripBridged` (sibling to the existing
   `internal.symlink`/`internal.cachegen` Go tools).

3. **RFC update**: promote § Consumer interface's SHOULD NOT → MUST
   NOT for `gomod2nix.toml` bridged entries; add a new MUST for the
   sentinel-required require line. Update § Limitations to remove
   the now-resolved caller-managed-require open item and the silent
   missing-thread open item.

4. **`mkGoPkgs(7)` / FDR-0003**: cross-reference the new checks
   from adopter-facing docs.

5. **Tests**: extend `internals-merge-test.nix` with:
   - Negative case: consumer's gomod2nix.toml drifted with bridged
     key → expected throw.
   - Negative case: consumer's go.mod has non-sentinel pseudo for
     bridged key → expected throw.

## Resolved sub-decisions

1. **No migration grace period — checks throw on first eval.**
   Existing adopters (#42's table: madder, tap, tommy, purse-first,
   maneater, plus pending nebulous and dodder) clean their drift in
   the adopter-sweep step of the rollout below, *before* the checks
   land. The check itself ships as a hard error from day one; no
   warning-then-error promotion path, no `strictBridgeChecks` flag.
   Rationale: a grace period preserves the silent-drift class for
   the duration of the grace period, which defeats the point of
   landing the check.

2. **Bridged-keys list is baked into the wrapper script at
   flake-eval time.** The `mkGoEnv` `go` wrapper is already a
   `writeScript`-generated artifact; it interpolates the
   `goFlakeInputs` keys as a bash array literal. No sidecar file,
   no read step at runtime, no on-disk state adopters can drift
   from.

   ```bash
   # writeScript-generated; keys interpolated at flake-eval time:
   STRIP_KEYS=(
     "github.com/amarbel-llc/tap/go"
     "github.com/amarbel-llc/dewey"
   )
   ${gomod2nix}/bin/gomod2nix generate
   ${strip_helper} gomod2nix.toml "${STRIP_KEYS[@]}"
   ```

   The `go` wrapper layer is itself vestigial once the fork
   transitions to a go2nix-inspired story (see FDR-0001). When the
   producer-side build owns module-graph synthesis directly, there's
   no `gomod2nix generate` step to post-process and the wrapper goes
   away entirely. Until then, this is the strip enforcement point.

3. **`nix build` MUST NOT mutate the on-disk `gomod2nix.toml`.**
   The bridge throws an eval-time error if drift exists; the fix
   is to run `gomod2nix generate` in `nix develop` (where the
   wrapper auto-strips). `nix build` stays reproducible —
   re-running it never silently changes the worktree.

4. **Multi-module producers (purse-first-shape) are already
   handled.** Each `mkGoEnv` call has one `pwd`, one
   `gomod2nix.toml`, one `goFlakeInputs`; the wrapper's strip
   target is naturally scoped per-call-site. purse-first as a
   *producer* exposes multiple Go modules (`libs/dewey`,
   `libs/go-mcp`, etc.) under one workspace and one `go-pkgs`
   derivation, which consumers bridge via different `subPath`s —
   this design works for that shape unchanged. The case this
   design defers is a *consumer* with multiple separate
   `gomod2nix.toml` files (one per consumer-side Go module). No
   such adopter exists in #42's table; add a fixture if one
   surfaces.

5. **#41 lint ships as a follow-up after this structural fix.**
   With both pins always-invalid-for-bridged-modules, missing
   threading is a hard build failure — the lint's value
   collapses to "catch the bug at flake-eval rather than at
   build". Still worth ~30 LOC for the faster iteration loop,
   but lower-priority than the structural fix. Sequenced last in
   the rollout below.

## Rollout

Suggested commit ordering (each can be its own PR):

1. **Adopter migration sweep** — update each consumer in #42's
   table to clean state (drop bridged toml entries, set require
   lines to sentinel pseudo-version). One commit per adopter
   repo. Lands *before* the enforcement so the enforcement is
   green on day one.
2. **Eval-time checks** in `internals.nix`: throw on drifted
   `gomod2nix.toml` entry and non-sentinel `go.mod` require.
   Tests + docs. Hard error from day one — no grace period.
3. **`mkGoEnv` go-wrapper post-strip**, with bridged keys baked
   into the wrapper script. Tests via `zz-pocs/goflake-poc/`.
4. **RFC 0001 amendment** promoting SHOULD NOT → MUST NOT and
   adding the sentinel-required clause.
5. **#41 lint** as a follow-up — simpler now that the structural
   fix is in place.

## References

- RFC 0001: `docs/rfcs/0001-flake-input-go_mod.md`
- Bridge internals: `pkgs/build-support/gomod2nix/internals.nix`
- mkGoEnv go-wrapper: `pkgs/build-support/gomod2nix/default.nix:541-555`
- Originating issues: #37, #51, #41
- Adoption tracker: #42
- Companion (just landed): #36 — depth-1 passthru inheritance
- Companion (deferred): #61 — advisory coverage warning
