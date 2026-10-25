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
| #73 | godyn-gen -gomod for go.work consumers | fixture-driven (a two-member workspace); FDR 0008 says one go.nix per module is the end state, so this may be a "document the migration" item instead | medium |
| #88 | frozen, no-resolve mode for godyn-go | a flag on the escape hatch plus a fixture asserting no network/`go get`; design is in the issue | medium |
| #77 (main) | aarch64 static link falls back to host gcc | reproducible only with a cross Go toolchain build (heavy on this host); the side-finding is fixed in ec60569 | large |

## (b) Needs a decision (options)

| # | Item | Options |
|---|---|---|
| #29 | Productionize godyn (umbrella) | close as superseded by FDR 0007 (now proposed), or keep as the darwin/aarch64 tracker alongside #33 |
| #75 | per-system IFD limit | keep open as the discoverable record (the issue says so), or close and point at FDR 0008 § Decision |
| #25 | nixpkgs→igloo reference sweep | close with `2026-10-24-nixpkgs-issue-refs.md` (no map exists), or retitle to "triage the 25 still-open archived threads" |
| #87 | golangci-lint parity for godyn-lint | accept godyn-lint's suite as the fleet standard; port specific linters; or keep buildGoLint for consumers that need parity |
| #85 | gopls/dlv without a committed go.mod | FDR 0008 descoped them; a POC needs a direction (rendered module + -modfile vs a gopls from a derivation) |
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
