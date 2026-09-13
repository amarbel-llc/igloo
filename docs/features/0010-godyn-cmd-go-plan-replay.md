---
status: exploring
date: 2026-09-13
promotion-criteria: >-
  To proposed: a spike replays cmd/go's captured plan per package for the
  gotest, multi, race and a cgo fixture, and for each step either matches
  godyn's current archive after buildid normalization or explains the
  difference; the open questions below are answered.
---

# godyn: replaying cmd/go's build plan per package

## Problem Statement

godyn re-implements, in Nix, what cmd/go does for each package. Every build mode
or flag is a hand port: `-race` (igloo#34 item 3), the mode layer (msan, asan,
gcflags, asmflags), and `-cover`. `-cover` alone meant reading `cmd/go/internal/work`
and `load/test.go` to reproduce the `go tool cover` pass, its `pkgcfg.txt`, the
`-coveragecfg` compile, and the testmain template's cover block, which
`go list -test` does not render. Each new cmd/go flag, and each Go release that
changes a step, needs another port. Downstream consumers only get the modes
someone has ported. The question is whether godyn can take the per-package steps
from cmd/go itself and keep only the per-package, content-addressed boundary. That
would make modes and flags work without a port.

## Interface

A sketch only, and deliberately open. The spike decides whether any of it holds.

- **Capture.** In the graph-derivation sandbox, alongside `godyn-gen`, run
  `go build -n <flags> ./...` and `go test -n <flags> ./...` with the consumer's
  flags (`-race`, `-cover`, `-covermode`, `-tags`, `-gcflags`, …). `-n` prints the
  shell commands cmd/go would run, per action (`$WORK/bNNN`), without running them.
- **Split.** Parse the plan into per-package steps: tool invocations
  (`compile`, `asm`, `cgo`, `cover`, `link`) and their file inputs (heredoc
  importcfg/embedcfg, `echo … > pkgcfg.txt`). Record them in the graph JSON next
  to each node.
- **Replay.** Each godyn package derivation runs its package's recorded steps,
  rewriting `$WORK/bNNN` to the derivation's work dir and dependency
  `$WORK/bMMM/_pkg_.a` to dependency store paths (the same wiring godyn does for
  importcfg today). godyn owns the steps cmd/go runs outside tools: `-buildid`,
  trimpath, `-o`, stdlib, and the CA output layout.
- **Opt-in.** A `planReplay = true` switch on `buildGodynModule`, which makes
  the hand-ported path and the replay comparable on the same fixture before either
  replaces the other.

## Examples

Evidence from a scratch capture on the gotest fixture, Go 1.26.6 linux/amd64
(`go build -n`, `-race`, `-cover`, `-cover -coverpkg=./...`, `go test -n -cover`):

    # plain
    compile -o $WORK/b003/_pkg_.a -trimpath "$WORK/b003=>" -p example.com/gotest/leaf
      -lang=go1.26 -complete -buildid B676…/B676… -goversion go1.26.6 -c=8
      -nolocalimports -importcfg $WORK/b003/importcfg -pack ./leaf/leaf.go
    # -race adds, and nothing else changes on the compile line:
      -installsuffix race … -race
    # -cover inserts a step and changes the compile inputs:
    cover -pkgcfg ./pkgcfg.txt -mode set -var goCover_<12 hex>_ -outfilelist ./coveroutfiles.txt …
    compile … -coveragecfg=$WORK/bNNN/coveragecfg … $WORK/bNNN/covervars.go $WORK/bNNN/leaf.cover.go
    # go test -cover: the testmain gets its own pkgcfg and `cover -mode testmain`

godyn's current compile for the same package, for comparison:

    go tool compile -importcfg importcfg -p example.com/gotest/leaf -buildid ""
      -trimpath="<src>=>example.com/gotest/leaf;$NIX_BUILD_TOP=>"
      -nolocalimports -pack -lang=go1.26 -o $out/pkg.a <src>/leaf.go

The plan already expresses what the stage-2 `-cover` port had to discover by
reading source. A replay would have picked that up without any Nix changes.

## Limitations

- **`-n` is a human-readable shell transcript, not an API.** Its format isn't
  covered by the Go compatibility promise, so a parser can break on any release.
  `go build -json` reports build output events, not the plan.
- **The plan assumes cmd/go's work layout.** Action IDs, `$WORK/bNNN`, heredoc
  importcfgs, and `cd` into the package dir all need rewriting. Steps marked
  `# internal` (`buildid -w`, `echo`/`cat` config writes) are cmd/go actions,
  not commands.
- **Build IDs differ by design.** cmd/go passes content-derived `-buildid A/A`.
  godyn passes `-buildid ""`, and its CA identity comes from the store path.
  Archives can't be byte-identical to cmd/go's. The meaningful comparison is
  against godyn's own archives with build IDs normalized.
- **An empty GOCACHE plans the whole stdlib.** The capture contains every std
  package. Replay would filter to graph nodes and keep godyn's stdlib
  derivation, which must be built with the same mode flags (the race stdlib
  already is).
- **Flags godyn does not pass today**: `-complete`, `-goversion`, `-c=8`,
  `-installsuffix`. Whether they change archive bytes is unverified (a theory
  for the spike to test). `-c` is compiler concurrency and plausibly doesn't
  change output. `-complete` enables compiler checks.
- **No cgo evidence yet.** The captured fixture has no cgo, asm or bridged
  modules. The cgo step's `-objdir`, the `_cgo_*` files and the external-link
  plan are the hardest part to rewrite.
- **Conditional steps.** cmd/go chooses some steps from inputs it inspects when
  it runs, such as EmitMetaFile for untested covered packages and vet. A
  captured plan freezes those choices at graph-derivation time. That fits
  godyn's eval-time graph but needs checking per mode.

## Open questions

1. Parse `-n` text, or get the plan another way (a `cmd/go` patch or
   `go build -toolexec` logging the real tool argv and inputs per action)?
   `-toolexec` sees the actual invocations, with inputs already written.
2. What is the unit of replay: raw tool argv per step, or a normalized step
   schema (tool, flags, inputs, generated files) that godyn renders?
3. Can the replay path stay byte-identical to godyn's current archives for the
   default (no-mode) build, so that switching is a no-op fleet-wide, the same
   rule every godyn option follows today?
4. How do per-package test plans (variant, xtest, recompiled dependents,
   testmain) map onto godyn's test derivations?
5. Is a hybrid enough: keep hand ports for the base build and replay only the
   steps a mode inserts (cover, cgo sanitizer flags)?

## More Information

- FDR 0007: godyn plus flake-input-go_mod as the only Go build path.
- FDR 0008: no committed graph; the plan would ride the same eval-time graph.
- FDR 0009, Future Work: Nix evaluator plugins. A plugin could run cmd/go's
  loader and planner at eval time instead of parsing a transcript.
- igloo#34: godyn test and mode gaps, where `-race` and `-cover` were ported by hand.
- Capture recipe used for the evidence above: `go build -n` / `go test -n`
  under `runCommandCC` on `pkgs/build-support/godyn/tests/gotest`, with
  `GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=1`.
