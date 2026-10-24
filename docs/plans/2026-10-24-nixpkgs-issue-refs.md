# `amarbel-llc/nixpkgs#N` references: no map exists, leave them

Resolution note for igloo#25 ("Sweep stale amarbel-llc/nixpkgs references →
igloo"), written 2026-10-24 by session igloo/slim-pecan before any reference
was rewritten. Companion to `2026-05-29-rename-to-igloo.md`.

## What igloo#25 assumed

That the issues open in `amarbel-llc/nixpkgs` at the rename were transferred
to igloo and renumbered, leaving GitHub redirects, and that references to them
should therefore be rewritten with this old → new map:

    4→1   12→2  15→3  16→4  23→5  28→6  29→7  30→8  35→9  37→10
    41→11 42→12 51→13 56→14 57→15 58→16 59→17 60→18 61→19 62→20
    63→21 65→22 66→23 67→24

## What was observed

- **The archived repository still holds every one of those issues, open.**
  `https://github.com/amarbel-llc/nixpkgs/issues?q=is:issue+is:open`
  lists 25 open issues: #4, #12, #15, #16, #23, #28, #29, #30, #35, #37, #41,
  #42, #51, #56, #57, #58, #59, #60, #61, #62, #63, #65, #66, #67 and #68 —
  the map's 24 numbers plus #68. A transferred issue leaves its source
  repository, so none of these were transferred. Opening one directly
  (`amarbel-llc/nixpkgs#41`, "Lint buildGoApplication/mkGoEnv calls with
  modules but no goFlakeInputs") shows the archived repository's page with no
  redirect.
- **igloo's low numbers are unrelated issues.** igloo#11 is "Support
  `impure-derivations` experimental feature in nix-daemon config"; igloo#12
  (closed) is "audit dev-shell PATH and remove ~/eng/result/bin"; igloo#10 is
  the justfile-conventions issue. The map would have sent nixpkgs#41's
  bridge-lint discussion to the nix-daemon issue, nixpkgs#42's adoption
  tracker to the dev-shell PATH issue, and so on. Their subjects (home-manager,
  agents, dev-shell PATH, notifications) point at a different source
  repository than nixpkgs; which one was not confirmed and does not matter
  here.
- **The references in igloo.** `rg amarbel-llc/nixpkgs`, excluding the rename
  plan that is about the rename, finds 83 lines in 29 files: docs/plans (6),
  docs/rfcs/0001, docs/decisions (2), docs/features (3), README.md, AGENTS.md,
  the gomod2nix build-support `.nix`/`.scd` files and their test fixtures,
  the bun2nix tool comments, and zz-pocs/goflake-poc. The issue numbers they
  cite are #5, #11, #12, #13, #31, #32, #33, #35, #36, #37, #38, #39, #40,
  #41, #42, #43, #44, #45, #46, #47, #48, #49, #50, #51, #52, #57 and #60.
  README.md:85 and AGENTS.md:8 refer to the archived repository by name as the
  pre-rename history, which is correct and deliberate.

## Recommendation

**Leave every `amarbel-llc/nixpkgs#N` reference as written.** They all resolve
today — open and closed alike — in the archived repository, which GitHub keeps
read-only and does not delete; nothing depends on a redirect, so the
"future-proofing" the sweep aimed at has nothing to proof against. Rewriting
to igloo numbers would break them. The same applies to the eng repository and
the sibling repositories the issue lists; the audit of igloo's design records
(`2026-10-24-fdr-rfc-audit.md`) likewise left these links alone and annotated
only the pre-rename *commit* hashes, which are the references that genuinely
do not resolve in igloo.

The one open question is not about references: several of the 25 archived
issues are live design threads (#37 lockstep collapse, #41 bridge-threading
lint, #42 protocol adoption tracker, #51 dropping organic requires, #60
`//go:embed`-derived extras, #61 coverage warning, #62 goSrc filtering) that
may deserve re-filing in igloo if anyone still intends to act on them. That is
a triage decision for the operator, recorded here so it is not mistaken for a
reference sweep. Whether `rg` should also stop matching the three igloo issue
refs the RFC writes as bare `nixpkgs#N` links is cosmetic and left alone.

## Status

igloo#25 carries this finding as a comment (2026-10-24). No file was changed
by the sweep; this note is the deliverable.
