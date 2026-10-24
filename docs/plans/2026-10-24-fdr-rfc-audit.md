# FDR / RFC audit — 2026-10-24

Audit of `docs/features/` (FDR 0001–0012) and `docs/rfcs/` (RFC 0001) against
the tree at master `793dcbe` (session igloo/slim-pecan). Per record: is the
status true, do the claims match the code and manpages, do links and issue
refs resolve, is anything shipped but undocumented or documented but unbuilt.

Each finding says what was **observed** (a file, a `git rev-parse`, a flake
attribute, an issue state) versus what was only **read** (a claim in a record
about another repository, which this session did not research — other repos
are their own sessions' lanes). Plain drift is fixed in the same change as
this note; anything that is a judgement is listed under *Needs a decision*.

## Summary

| Record | Status before | Verdict | Action |
|---|---|---|---|
| FDR 0001 numtide go2nix | exploring | stale: the record itself decides (2026-06-04) to roll our own builder; godyn is that builder | → `superseded by FDR-0007`, banner added |
| FDR 0002 nix mdbook → mandoc | exploring | true: no code in tree (`rg buildNixManpages\|nix-manual` outside docs: none); `nix-man` check exists (flake.nix:860) | dead pre-rename commit ref annotated |
| FDR 0003 bridge | superseded (RFC 0001) | true; `passthru.bridge`, `bridgeCapabilities`, `coverageGaps` observed (internals.nix:14, default.nix:782/1175) | dead pre-rename commit ref annotated |
| FDR 0004 go-pkgs producer | superseded (RFC 0001) | status true; two sentences stale (helper "not yet landed", "no producer has adopted"); one dead anchor into the RFC | fixed |
| FDR 0005 fast direnv | exploring | true: Interface/Examples still TBD, no code | none; see decisions (dormant?) |
| FDR 0006 hermetic check lanes | experimental | code observed (`buildGoCheck` default.nix:1299, `mkGoLintCacheEnv` :1404, `buildGoLint` :1484); gomod2nix(7) § Hermetic check lanes exists (gomod2nix.7.scd:482) so "will be updated once this lands" is stale | fixed; promotion criterion needs a decision |
| FDR 0007 godyn-only Go | exploring | two gap-table rows stale (igloo#70 fixed 793dcbe; igloo#71 closed, x/tools unpinned 9a7a651); one limitation cites igloo#72 as a live drift check (closed) | fixed; promotion needs a decision |
| FDR 0008 go.nix manifest | experimental | claims match: every check it names exists in `checks` (godyn-manifest-*, godyn-codegen-patch-*, godyn-test-with-test, godyn-derived-*; flake.nix:1080–1300); one "still to come" sentence is contradicted by the same record's later sections | fixed; promotion needs a decision |
| FDR 0009 rustdyn | proposed | true (this session's record; spike results in `zz-pocs/rustdyn-poc/README.md`) | none |
| FDR 0010 godyn plan replay | exploring | true: no `planReplay` in tree | none |
| FDR 0011 VM test lane | testing | true: `mkVmChecks`/`vmTestPrelude` (pkgs/build-support/vm-tests/default.nix), `vm-tests-smoke` check (flake.nix:1316) | none |
| FDR 0012 toolchain scope | experimental | igloo side true: `go-toolchain-scope` check (flake.nix:867), registry default 1.26.10 at audit time (1.27.3 after igloo#89, same day); fleet migration list is other repos' state | none; see *Not verifiable* |
| RFC 0001 flake-input-go_mod | draft | stale: its own draft → proposed criteria are met (FDR 0003/0004 thinned; `mkGoPkgs` exported, mk-go-pkgs.nix:93; producer/consumer fixtures `godyn-producer-*-test`); leftover depth-1 wording contradicts the depth-N amendment; per-package caching still deferred to the numtide FDR | → `proposed`; wording fixed; normative conflicts need a decision |

## Fixed in this change (plain drift)

1. **FDR 0001 status.** *Read:* "Decision recorded this session: roll our own
   instead of consuming numtide" (§ POC validation, 2026-06-04). *Observed:*
   godyn is that builder (`pkgs/build-support/godyn/`, godyn(7), FDR 0007); no
   `go2nix` attribute exists in the overlay. Status set to
   `superseded by FDR-0007` with a banner. Alternative if the operator
   prefers it: `deprecated` (never built, rejected). Revert is one line.
2. **RFC 0001 status `draft` → `proposed`.** Its draft → proposed criteria:
   "at least one producer publishes the dual outputs" (*read:* tommy, crap,
   cutting-garden, nebulous per FDR 0008 § tracers; *observed:* the in-tree
   producer fixtures `godyn-producer-consumer-test`, `godyn-producer-gonix-test`,
   `godyn-producer-subpath-test` publish and consume them) and "FDR-0003 and
   FDR-0004 are thinned to reference this RFC" (*observed:* both carry the
   superseded banner and link the RFC's sections).
3. **RFC 0001 depth-1 leftovers.** § *Depth-N inheritance with a
   conflict-guardrail* (igloo#58) made recursion normative, but § Limitations
   ("inherited … at depth-1 only"), § *Chains deeper than one level* (lead
   sentence, worked example) and Appendix A item 4 still said depth-1.
   *Observed:* mk-go-pkgs.nix:119–125 documents depth-N passthru union.
   Reworded; the worked example's duty-P/duty-C discipline stands.
4. **RFC 0001 per-package caching pointer.** Was "deferred to FDR-0001
   (numtide go2nix)"; now points at godyn / FDR 0007.
5. **FDR 0004.** Anchor `#producer-interface-packagessystemgo-pkgs-and-mkgopkgs`
   did not match the RFC heading "Producer interface: dual `go-pkgs` outputs
   and `mkGoPkgs`" (slug `#producer-interface-dual-go-pkgs-outputs-and-mkgopkgs`).
   The example's "Until the helper lands in the overlay" and the Limitations
   bullet "No producer has adopted yet. Status is `exploring`" contradicted
   *observed* mk-go-pkgs.nix:93 and the record's own superseded status.
6. **FDR 0006 More Information.** "gomod2nix(7) … will be updated to point at
   the hermetic lane once this lands" — *observed:* gomod2nix.7.scd:482 § Hermetic
   check lanes and :460 recommend `buildGoLint`.
7. **FDR 0007 gap table.** igloo#70 (bga eval without `version`) *observed*
   fixed by 793dcbe (`optionalAttrs (defaultPackage == "")` names the
   derivation; check `godyn-auto-goflakeinputs-bga-test`). igloo#71 *observed*
   closed; 9a7a651 "type-bearing vetx protocol … unpin x/tools". § Limitations
   said igloo#72 "keeps committed graphs honest"; *observed* igloo#72 closed,
   and FDR 0008 § Decision records the eval-time graph superseding it.
8. **FDR 0008.** "Still to come: the escape hatch … and a fleet consumer"
   (§ Progress, manifest) is contradicted by the record's own § Escape hatch
   (landed 2026-09-14) and the spinclass cutover paragraph.
9. **Dead commit references.** `bc09e11ab802` (FDR 0002), `f99a3ff43278`
   (FDR 0001, FDR 0003, RFC 0001) do not resolve in igloo (`git rev-parse
   --verify` fails); they are pre-rename history in the archived
   amarbel-llc/nixpkgs. Annotated in place, not removed. `899189e`, `c0dfbe9`,
   `ca00931`, `82f3d8e`, `8b8cab2`, `ddd99f2` cited by FDR 0008/0012 and the RFC
   do resolve.

Dates of every edited record set to 2026-10-24.

## Needs a decision

1. **FDR 0007 exploring → proposed.** Criteria: godyn is the default build of a
   fleet consumer with a full package, buildGoApplication demoted to an escape
   hatch, known gaps tracked. *Read* (FDR 0008): spinclass cut over at
   `13d42af`/`104a5a0`, conformist at `12ddb8a` with no strategy. *Observed:*
   `buildGoAuto`'s default strategy is `native` on `godynSystems`
   (build-go-auto.nix:90), so a consumer that pins no strategy builds with godyn
   on x86_64-linux. Gaps with issues: igloo#33 #34 #73 #75 #77 #78 #82 #85 #87
   #88, circus#219. Gaps in the table with no issue found: per-package vet
   skipping cgo packages and test sources; `nativeCheckInputs`-style tools on
   the test PATH (marked unverified there). The Problem Statement's "operator's
   decision to flip spinclass's default to godyn pending" and the Rollout's
   "spinclass's planned `.#spinclass-build_go_application`" need a look in
   spinclass. Recommendation: file the vet gap, confirm spinclass's default,
   promote.
2. **FDR 0008 experimental → testing.** Criteria: dependency updates only
   through the manifest on two consumers; each third-party module's Go version
   reaches its compiles. *Observed:* `godyn-manifest-test` asserts the
   third-party module compiles at its own go directive. *Read:* six go.nix
   consumers (spinclass, tommy, crap, cutting-garden, nebulous, conformist).
   Whether updates happen only through the manifest is a fleet observation.
3. **RFC 0001 normative conflicts.** (a) § *`mkGoEnv` parity*: "a consumer's
   `nix develop` shell MUST see the same module graph as `nix build`" — *observed*
   gomod2nix(7) § mkGoEnv devshell scope (gomod2nix.7.scd:353–397) and FDR 0006
   § Why not fix the devshell record that the bridge reaches mkGoEnv's vendor
   environment but not the ambient `go`, and that this has no pure solution.
   (b) § *The `gomod.nix` convention* (SHOULD) versus FDR 0008, where cut-over
   consumers have no go.mod and no gomod.nix (spinclass removed its gomod.nix);
   FDR 0008 says `flakeInputs` "supersedes RFC 0001's eval-time merge of an
   organic go.mod". (c) § *`goSourceFilterMiddleware`* shows `mkGoPkgs {
   middlewares = …; }`, which the same RFC defers and which mk-go-pkgs.nix:93–138
   does not accept (its arguments: src, name, extras, testExtras,
   goFlakeInputs, manifest, inputs, goFlakeInputOverrides, subPath).
   (d) "`mkGoPkgs` MUST NOT slice the tree by any caller-side `subPath`" — the
   manifest-mode `subPath` (8b8cab2) places the rendered go.mod, it does not
   slice; worth a sentence. Options: an amending revision of RFC 0001, or an
   RFC 0002 for the go.nix protocol that RFC 0001 then defers to. Also whether
   proposed → experimental is already met (madder#212 contract test, *read*;
   consumers building against both outputs, *observed* in fixtures).
4. **FDR 0006 promotion criterion is unreachable as written.** It names
   spinclass exposing `buildGoLint`; FDR 0008 records spinclass retiring
   golangci-lint for godyn-lint, and FDR 0007 says FDR 0006 is superseded once
   consumers are godyn-native. Decide: retarget the criterion, or mark 0006
   superseded by FDR 0007 when the last `buildGoLint` consumer leaves (which
   consumers use it is a fleet question). Related: igloo#62 is open while FDR
   0006 and gomod2nix(7) both call it resolved by the hermetic lanes.
5. **FDR 0001 superseded (applied, item 1 above).** Confirm `superseded by
   FDR-0007` or change to `deprecated`.
6. **FDR 0002 and FDR 0005** have been `exploring` with no code since May and
   March. Keep, or mark `dormant` (code parked / no active home is not quite
   the case; "exploration paused" has no status in the FDR lifecycle). Low
   priority.
7. **FDR 0003 / FDR 0004 front matter** uses `status: superseded` plus a
   `superseded-by:` field, not the lifecycle's `superseded by FDR-NNNN` form
   (the successor is an RFC, which the form does not anticipate). The design
   index renders them correctly today. Note only.

## Decisions taken (operator, 2026-10-24)

Applied in the same day's follow-up change:

1. **FDR 0007 → proposed** (criterion marked MET; the untracked vet gap is now
   igloo#90).
2. **FDR 0008 → testing** (criterion marked MET).
3. **RFC 0001 → experimental**, with three amendments: § *`mkGoEnv` parity*
   now says what the merge reaches (the vendor environment and the sandbox,
   not an ambient `go`) and withdraws the "same module graph as `nix build`"
   promise; § *The `gomod.nix` convention* is scoped to organic-go.mod
   consumers; § *`goSourceFilterMiddleware`* no longer shows a
   `mkGoPkgs.middlewares` argument that does not exist.
4. **FDR 0006 → superseded by FDR-0007**, with a banner; igloo#62 closed on
   the devshell argument both records make.
5. **FDR 0001 superseded** confirmed (item 5 above stands as applied).

Still open: FDR 0002/0005 (idle), the FDR 0003/0004 front-matter form, and
the re-filing triage for the archived nixpkgs threads
(`2026-10-24-nixpkgs-issue-refs.md`).

## Not verifiable from igloo

- Other repositories' state cited by FDR 0007, 0008, 0012 and the RFC
  (spinclass's default output, the FDR 0012 migration list — circus,
  ringmaster, purse-first — madder#212, lazy-trees). These are their sessions'
  lanes or a fleet grep from circus.
- External issue links in FDR 0003 (dodder#125, dodder#126, clown#39) and the
  archived amarbel-llc/nixpkgs issue links throughout: not fetched. igloo issue
  numbers ≤ 89 all exist (GitHub never reuses numbers), so igloo#N refs are
  live; those checked for state: #70 #71 #72 closed, #62 #87 open.
- igloo#25 (sweep of `amarbel-llc/nixpkgs` references) was found separately to
  carry a wrong renumbering map (nixpkgs#41 is still open in the archive and is
  not igloo#11); the archived-repo links in these records were therefore left
  as they are.

## Out of scope, noted

- `docs/plans/*.md` and `docs/decisions/0002-*.md` cite pre-rename hashes
  (`1de9819`, `088f67bc126c`) that do not resolve in igloo. Plans are
  historical; the ADR could take the same annotation as item 9 above.
- Shipped but undocumented in any FDR: nothing found that lacks a manpage —
  nixgc(1), vm-tests(7), go-toolchain(7), godyn(7), gomod2nix(7), mkGoPkgs(7),
  goSourceFilter(7) cover the build-support tree; bun2nix (`buildBunBinary`,
  the lint stack) has an ADR (0002) and checks but no FDR or manpage.
