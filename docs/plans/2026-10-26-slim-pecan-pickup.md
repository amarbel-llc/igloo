# igloo/slim-pecan pickup note (2026-10-26, focus change)

Written by session igloo/slim-pecan when the coordinator halted unrelated
work (fleet pivot to unattended operation). Labels: **V** observed, **R**
read, **I** inferred. Everything here is on branch `slim-pecan`; nothing in
this note needs that session — a fresh one in this worktree (or any igloo
session) can continue.

## State

- `origin/master` = `380e3ad` (**V**): RFC 0003, the standard godyn tree
  (igloo#81 closed). Follow-ups filed: igloo#92 (godyn-go/godyn-test default
  `-A` to `go-module`), igloo#93 (conforming fixture flake).
- Branch `slim-pecan`, **unmerged**, two commits past master:
  1. `78ffc6f` — gomod2nix vendor-env fix for spinclass#157 (igloo#94,
     `Closes #94`): bridged goFlakeInputs trees become vendor-env inputs
     (string context) and nested bridged module paths materialize via
     symlink.go's deepest-first pass. Fixture `godyn-producer-nested-test`
     (package + check): red reproduced the exact error, green on both
     backends (**V**, built here before the gate).
  2. the commit carrying this note — fixes the one gate failure below,
     records the nixedit decision in FDR 0013, adds `just
     explore-rustdyn-cargo`.
- The merge gate for `78ffc6f` (`merge-4ff9f266`) **failed** on the
  existing check `godyn-producer-manifest-test` with "vendor tree carries
  q" (**V**, its log). Cause (**V** by reading): the check asserted
  `[ ! -e <vendorEnv>/example.com/q ]`, which held only because the bridged
  symlink dangled inside the check's sandbox (the vendor-env never
  referenced its target — exactly igloo#94's bug). After the fix the link
  resolves. The check now asserts the vendor tree's `q` IS the bridge:
  `readlink -f` of it equals `q.go-pkgs`. **Unverified (I):** the rewritten
  check has not been built (the halt forbade new nix work).

## Next, in order (exact commands, from this worktree)

1. Headroom first (fleet rules: memory > 6 GB available, load1 < 20, no
   other igloo gate running), then verify the check fix:

       just explore-build checks.x86_64-linux.godyn-producer-manifest-test
       just explore-build checks.x86_64-linux.godyn-producer-nested-test

2. Merge: `merge-this-session-async` with `targets: []` (pre-merge skills
   attestation is required first: `nothing-but-the-truth`; the one recorded
   for `78ffc6f` was consumed by the failed gate, record a new one).
3. Tell spinclass/firm-mulberry (session key on the fleet roster) the
   master SHA: they re-apply the go.nix hunk from their chat message
   chat-cd86c9b5 (both `flakeInputs` entries for
   `code.linenisgreat.com/purse-first/libs/go-mcp` and
   `…/libs/go-mcp/command/huh`, both `require`s removed) after bumping
   their igloo input. igloo owes them the SHA; the diagnosis was sent
   (chat-6ce73952).

## Queue after the merge (operator decisions already taken, 2026-10-26)

- **First real `cargoRun` (network cleared by the operator):**

      just explore-rustdyn-cargo -A packages.x86_64-linux.rustdyn-manifest-test \
        -m pkgs/build-support/rustdyn/tests/manifest/cargo.nix -- cargo add itoa@1
      just explore-build rustdyn-manifest-test     # importCargoLock fetches itoa (FOD)

  Then decide whether the manifest fixture keeps the registry crate (it
  becomes the first registry-dependency fixture; the round-trip check
  compares the ingested tree against the normalized manifest, so it should
  still hold — **I**) and move the matching rustdyn(7) LIMITATIONS lines
  from **I** to **V**. `cargoRun` needs `impure-derivations` (on, on flic).
- **nixedit Nix wiring (FDR 0013, operator chose shape 3 on 2026-10-26):**
  go.nix only; doppelgang bridges igloo's `go-pkgs` through `flakeInputs`
  (the #64 "plain go.mod dependency, no flake edges" half is reversed —
  recorded in FDR 0013 § Dependencies, igloo#64 and doppelgang#35). Steps:
  1. seed `pkgs/build-support/nixedit/go.nix` with `module` and `go`;
     network: `nix build .#go .#gomod2nix`, run `gomod2nix generate` in the
     nixedit dir (langlang/go plus testify's four modules), then
     `just explore-godyn-go -m pkgs/build-support/nixedit/go.nix -I pkgs/build-support/nixedit`;
     delete go.mod, go.sum, gomod2nix.toml (a go.nix module may not track
     them).
  2. flake.nix: `packages.<system>.nixedit = buildGoAuto { pname = "nixedit";
     src = ./pkgs/build-support/nixedit; manifest = ./pkgs/build-support/nixedit/go.nix;
     tests = true; version = …; }`; checks `nixedit-test` (checkAll),
     `nixedit-vet`, `nixedit-lint`; igloo's RFC 0001 producer pair
     `go-pkgs` / `go-pkgs-test` = `mkGoPkgs { src = self; manifest = …;
     subPath = "pkgs/build-support/nixedit"; }` (one pair per flake —
     nixedit is igloo's only Go library); `nixedit.1.scd` from
     `cmd/nixedit/main.go`'s package comment, built with `mkScdocMan` as
     `nixedit-man`; README row.
  3. doppelgang#35 gets the consumer entry:
     `flakeInputs."code.linenisgreat.com/igloo/pkgs/build-support/nixedit" =
     { input = "<doppelgang's igloo input>"; subPath = "pkgs/build-support/nixedit"; }`.
- **rustdyn stage 3 (operator: go on both sides, 2026-10-26):** write
  `mkRustCrates` in igloo (RFC 0002 § Producer interface; renders the
  manifests from cargo.nix, filters, attaches `passthru.flakeInputs` and
  `passthru.members`) with a fixture consumer, then hand posh's opt-in
  brief (`docs/plans/2026-10-25-rustdyn-stage3-posh-prereqs.md`) to posh's
  live session over chat — no `spawn-session` (operator standing order
  until the ssh agent is stable), and only once the coordinator's focus
  allows it.
- Still open, decided: igloo#78 (second `godynStdlib` with `CGO_ENABLED=0`
  behind `buildGoStatic`), igloo#82 mitigation (c) facts-only runs, #92,
  #93; rustdyn measurements on a quiet host (FDR 0009 promotion criteria).
- **igloo#95 (filed 2026-10-26 from the nikulin cascade failure at
  madder):** godyn speaks unitchecker's new type-bearing vetx protocol only
  to a `vetTool` declaring `passthru.typedVetx`; purse-first's dewey
  analyzers crossed x/tools v0.50 without the label and fail with "no
  package vetx file for bufio". Operator ruling: the consumer-side label is
  dispatched to the coordinator (purse-first/madder, not igloo); igloo owes,
  in order, (1) a message naming the fix when that error appears plus
  godyn(7) § VET mentioning `typedVetx`, (2) detecting the dialect from the
  tool's x/tools version (`go version -m`) so no label is needed.

## Records to read first

`docs/plans/2026-10-25-issue-triage.md` (every decision round),
`docs/rfcs/0003-standard-godyn-tree.md` § Decisions, FDR 0009 (rustdyn)
and FDR 0013 (nixedit). Forge: issues live on code.linenisgreat.com under
`linenisgreat/igloo` (GitHub is a mirror).
