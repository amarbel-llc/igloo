# igloo open-issue triage — 2026-10-25

41 open issues at the time of writing (after the 2026-10-24 closes of #40 #46
#53-pending #62 #70 #76 #79 #86 #89 #91-pending). Labels: **V** observed in
this tree or on this host, **R** read in an issue or another repo's record,
**I** inferred. Written by session igloo/slim-pecan for the overnight queue;
"tonight" means no operator, no card, no lock bump, no outward-facing edit.

## (a) Fixable tonight, tests first — smallest risk first

| # | Item | Why it is (a) | Size |
|---|---|---|---|
| #91 | buildGoAuto drops the manifest commit on bga | fixed in 14620df with a fixture (V), in the merge in flight | done |
| #53 | ldflagsX key naming a package-main symbol | fixed in ec60569 with a fixture (V), in the merge in flight | done |
| #34 (item 5) | flaky-test re-run knob | `passthru.testWith` already takes per-run test flags, so `-test.count=2` yields a new run derivation (R: godyn(7) § TESTS); verify, then close the item or add the one-line knob | small |
| #90 | vet/lint do not analyze test sources; toolchain-vet skips cgo | the test-variant archives exist (godyn(7) § TESTS), so a per-test-variant run is the existing run shape over different inputs; a fixture with a `_test.go` finding is the test | medium |
| #77 (main) | aarch64 static link falls back to host gcc | reproducible only with a cross Go toolchain build (heavy on this host); the side-finding is fixed in ec60569 | large |

Re-read after the first pass (2026-10-25, later): **#73** reframes itself, in
its last comment, into a multi-module fixture at repository root with a
sibling path replace between two go.nix modules — buildGodynModule renders
go.mod at `src`'s root, so a `../sib` replace needs a module-root/`src`-root
split that does not exist yet (I); that is design, not a night's fixture, so
it moves to (b). **#88** asks for `go test` run natively outside the sandbox,
which FDR 0008 declared unsupported (the same scope line as gopls/dlv); the
go.nix rewrite it reports is the escape hatch's documented ingest, not a bug
(answered on the issue). It moves to (b).

## (b) Needs a decision (options)

| # | Item | Options |
|---|---|---|
| #29 | Productionize godyn (umbrella) | close as superseded by FDR 0007 (now proposed), or keep as the darwin/aarch64 tracker alongside #33 |
| #75 | per-system IFD limit | keep open as the discoverable record (the issue says so), or close and point at FDR 0008 § Decision |
| #25 | nixpkgs→igloo reference sweep | close with `2026-10-24-nixpkgs-issue-refs.md` (no map exists), or retitle to "triage the 25 still-open archived threads" |
| #87 | golangci-lint parity for godyn-lint | accept godyn-lint's suite as the fleet standard; port specific linters; or keep buildGoLint for consumers that need parity |
| #85 | gopls/dlv without a committed go.mod | FDR 0008 descoped them; a POC needs a direction (rendered module + -modfile vs a gopls from a derivation) |
| #88 | frozen, no-resolve native `go test` through godyn-go | widen FDR 0008's scope to a native frozen mode (render go.mod/go.sum + vendor to scratch, `-mod=vendor`, no ingest), or keep tests in the sandbox and give godyn-test a way to put the module's own binary on the test PATH |
| #73 | multi-module repository with sibling path replaces (purse-first's shape) | a module-root/`src`-root split for go.nix modules (where the rendered go.mod lands vs. what the derivation sees), or one `src` per module with the sibling as a flake-input-style bridge |
| #82 | input bump invalidates per-package vet closures (~100 min gates) | shared vet cache across consumers (the fleet cache, see readiness note), facts-only runs for third-party packages skipped when unchanged, or accept |
| #81 | RFC for a standard godyn tree | write it (who owns: igloo) or fold into conformist's eng-go template |
| #78 | static-build lane (cgo-free stdlib variant) | build `godynStdlib` twice (cgo on/off) behind `buildGoStatic`, or keep bga for static release artifacts |
| #64 | lift doppelgang's nixedit into igloo | FDR first; cross-repo move |
| #63 | registry-style toolchains for Rust and Zig | rustdyn (FDR 0009, parked on the operator) owns the Rust half; Zig has no consumer yet |
| #61 | shared Rust build-support / GC-able target dirs | rustdyn stage 2 — parked on the operator; do not touch |
| #42 | source-build apple/container | darwin-only package policy |
| #41 #39 #26 | sentinel removal / go.work overlay / exclusion mechanism for bridged modules | all three are made moot for go.nix consumers by FDR 0008; decide whether organic-go.mod consumers still get them or they close as superseded |
| #20 | `follows` vs FlakeHub cache hits | survey/position paper; fleet-wide convention |
| #11 #10 #5 #4 #3 #2 | eng-level items filed here before the rename (nix-daemon features, justfile conventions, red-team agents, NixOS config, CI audit) | move to eng/circus or close; igloo is the wrong repo for all six (I) |

## (c) Blocked on another repo or host

| # | Item | Blocked on |
|---|---|---|
| #33 | godyn on darwin (CA stranding, darwin fixture validation) | a darwin builder; part 2 (per-system graphs) shipped (R: 84d0ab6); the upstream nix report nix-src#487 |
| #65 | warm golangci-lint cache misses on darwin | a darwin host to reproduce; FDR 0006 is now superseded, lowering priority |
| #59 | downstream depth-N adoption rollout | each consumer repo |
| #43 | fence sandbox denies PTY allocation | the sandbox (fence) lives in bats/eng, not igloo |
| #31 | audit users of the standalone gomod2nix fork | purse-first's lock and any other pinning repo |
| #19 | stats-me into ~/eng | eng |
| #16 #14 | piggyGuid bootstrap / piggy-agent allCards | piggy, eng host config |
| #13 | GitHub label pruning across the org | org admin |
| #8 | fish completions from nix profile packages | home-manager config in eng |
| #7 | validate-purse-first/validate-bob hang in the pre-merge hook | eng's sweatfile (no such recipes in igloo, V) |

## (d) Stale — verify, then close or retitle

| # | Verdict (evidence) |
|---|---|
| #7 | not applicable to igloo (V: no `validate-purse-first`/`validate-bob` in the tree); eng-level |
| #2 | pre-rename CI audit; igloo has no GitHub Actions workflows (V: no `.github/workflows` referenced in the tree); close or move |
| #66 | mkGoLintCacheEnv whitelist refactor: the lane it improves is superseded (FDR 0006 → superseded by FDR 0007, V); close as won't-do unless a buildGoLint consumer asks |
| #39 #41 #26 | see (b): made moot for go.nix consumers; stale unless an organic-go.mod consumer remains |

Everything in (b) goes to the decision sheet; (c) is other sessions' lanes; (a)
is worked in table order after the merge in flight lands.

## Decisions taken (operator, 2026-10-25)

- **#90 defaults:** fold the test variants into `vetAll` / `lintAll` now
  (parity with `go vet ./...`); consumers may see new findings in their tests
  on the next igloo bump. Done in this change; `vetTestsAll` / `lintTestsAll`
  remain as the tests-only view.
- **#88:** keep FDR 0008's scope — tests that need the module's own binary get
  it in the sandbox through a second instance in `nativeCheckInputs`
  (godyn(7) § TESTS, the `selfbin` fixture). A native frozen mode is the
  fallback only if that proves unworkable for a real consumer.
- **#73:** the module-root / src-root split for go.nix modules (a repository
  root `src` with a module directory, sibling path replaces resolving inside
  it, sibling manifests rendered). Done as `moduleDir` (the `multimod`
  fixture builds on both backends, V); testFiles / codegenCheck / escape hatch
  with `moduleDir` are not exercised yet (godyn(7) says so).
- **Housekeeping:** #29, #25, #41, #39, #26 closed as superseded / resolved;
  #11, #10, #5, #4, #3, #2 closed here as eng-level with pointer comments.

## Decisions taken (operator, 2026-10-25, second round)

The rest of (b), plus the two (a) items that were waiting on a ruling.

- **#90 remaining halves:** both now — analyze external test packages
  (`package foo_test`) and run the toolchain vet lane over cgo packages, a
  fixture for each.
- **#77 (main):** wait for an aarch64 host; blocked alongside #33 rather than
  cross-building a toolchain on the shared host.
- **#87:** godyn-lint's suite is the fleet standard. Document it in godyn(7)
  with the golangci-lint linters it lacks, then close.
- **#82:** both mitigations — push vet run derivations to the fleet cache
  (document the pattern) now; facts-only runs for unchanged third-party
  packages as a follow-on builder change.
- **#85:** keep descoped (FDR 0008); the issue stays open as the "wait for a
  consumer / use case" marker, no POC.
- **#81:** write the standard-tree RFC in igloo (`docs/rfcs/0002`) and have
  igloo's docs point at it.
- **#78:** a second `godynStdlib` with `CGO_ENABLED=0` behind a
  `buildGoStatic` entry point.
- **#75:** close, pointing at FDR 0008 § Decision.
- **#64:** copy doppelgang's nixedit into igloo's build-support now; file an
  issue on doppelgang to remove its copy and consume igloo's.
- **#63:** split — Rust is FDR 0009's; retitle #63 to the Zig registry and
  leave it open until a Zig consumer appears.
- **#42:** blocked on a darwin builder, alongside #33.
- **#20:** hand to circus/eng through the coordinator; igloo closes #20 with a
  pointer once it lands there. Landed as amarbel-llc/circus#379 (R, relayed
  by circus/eager-holly, 2026-10-25); the close waits on GitHub's rate limit.
- **#61 / rustdyn stage 2:** approved by the operator the same day (relayed by
  circus/eager-holly); stage 2 proceeds under FDR 0009 § Staged plan.
