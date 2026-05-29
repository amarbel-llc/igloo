---
date: 2026-05-29
status: proposed
old-name: amarbel-llc/nixpkgs
new-name: amarbel-llc/igloo
tracks:
  - amarbel-llc/nixpkgs#65  # transfers into igloo with the rest (see § Issue migration)
relates:
  - amarbel-llc/piggy#124
---

# Rename: amarbel-llc/nixpkgs → amarbel-llc/igloo

## Context

This repo is no longer a fork of nixpkgs. It started life as a full
NixOS/nixpkgs fork; it has since been reduced to a small **overlay
flake** that consumes upstream nixpkgs as an input (`nixpkgs-master`)
and layers on:

- build-support helpers (`gomod2nix/` Nix builder + `mkGoPkgs` + the
  `flake-input-go_mod` bridge; `bun2nix/`; `fetch-gguf-model/`),
- a thin set of pins (`claude-code`, `go_1_26`) and amarbel-only
  packages,
- the workspace's heavy docs culture (ADRs, FDRs, RFCs, plans).

Its job in the workspace is to be the **shared Nix build-support
layer** that ~20 sibling repos pull in as their `nixpkgs` input. The
name `nixpkgs` now actively misleads: it implies a full fork, and the
README spends two paragraphs disclaiming that. The decision is to
rename to a workspace-style codename — **`igloo`** (snow motif like
the rest of the Nix ecosystem's iconography; a *structure built from
snow blocks*, which is what this repo does with the nixpkgs snowpack;
ecosystem-neutral, so it won't become the next misnomer as more
build-support stacks accrete).

## Why a new repo, not an in-place GitHub rename

A GitHub rename keeps a redirect, which would make the cutover lazy.
We are **not** taking that path, for one reason: the git history is
heavy — it carries the entire inherited NixOS/nixpkgs ancestry, which
an overlay flake has no use for. So the migration is:

1. Create `amarbel-llc/igloo` as a fresh repo.
2. Seed it from the current working tree with a single **squashed root
   commit**, shedding the upstream ancestry entirely. The pre-rename
   history is not lost — it stays reachable in the archived old repo
   (step 5); a note in igloo's README + AGENTS.md points there for
   anyone who needs to spelunk the fork-era history.
3. Transfer issues over (see § Issue migration).
4. Cut every consumer over to the new URL.
5. **Archive** (not delete) `amarbel-llc/nixpkgs` — keeps the fork-era
   git history and the issue-transfer redirects alive.

Consequence: **no redirect.** Because the new repo does not inherit
the old name's redirect and does not carry upstream's commit history,
the cutover is *hard* — every consumer reference flips together, and
any reference that pins an old commit SHA breaks (see Class 2 below).

## Blast radius

`rg 'github:amarbel-llc/nixpkgs'` across `~/eng/repos` splits the
references into three classes with very different handling.

### Class 1 — plain flake-input URLs (mechanical, ast-grep)

The string literal `"github:amarbel-llc/nixpkgs"` (no pinned rev),
appearing as a flake input. 21 occurrences across 20 repos:

| Repo | File |
|---|---|
| bob | `flake.nix` |
| clown | `flake.nix` (the `nixpkgs` input only — not the pinned ones) |
| tap | `flake.nix` |
| nebulous | `flake.nix` |
| purse-first | `flake.nix` |
| tommy | `flake.nix` |
| maneater | `flake.nix` |
| stats-me | `flake.nix` |
| piggy | `flake.nix` **and** `vendor/pivy/flake.nix` |
| spinclass | `flake.nix` |
| chrest | `flake.nix` |
| cutting-garden | `flake.nix` |
| langlang | `flake.nix` |
| pa6e | `flake.nix` |
| madder | `flake.nix` |
| bats | `flake.nix` |
| crap | `flake.nix` |
| moxy | `flake.nix` |
| dodder | `flake.nix` |
| doppelgang | `flake.nix` |

The input **attribute** stays named `nixpkgs` — only the URL string
changes — so nothing downstream of the input declaration moves. This
is the invariant that keeps the blast radius to one line per repo.

### Class 2 — pinned-rev inputs (manual; the SHA does not transfer)

`"github:amarbel-llc/nixpkgs/<sha>"` — pins a specific commit:

| Repo | Input | Pinned SHA |
|---|---|---|
| clown | `nixpkgs-claude-code` | `b2b9662f…` |
| clown | `nixpkgs-codex` | `0de8465d…` |
| clown | `nixpkgs-llama` | `c0df0d08…` |
| clown | `zz-pocs/0002` `nixpkgs` | `9bad1e48…` |

These work today **only because this repo is a history-superset of
upstream** — clown's own comment says "same SHAs we used against
upstream, just served by the fork … each fork commit upstream's
master, so these SHAs are reachable." A fresh-history `igloo` will
**not** contain those commits. The fix is a semantic one, not a string
swap: re-point these at `github:NixOS/nixpkgs/<sha>` directly (which is
where the SHAs actually live). ast-grep deliberately leaves these
alone — the `clown/flake.nix` dry-run confirmed it matched only the
unpinned line.

### Class 3 — prose / comments / docs (rg sweep, NOT ast-grep)

Free text, which ast-grep cannot target (it matches AST nodes, not
comment bodies). Two sub-kinds:

- **Terminology** — "the amarbel-llc/nixpkgs fork overlay", "served by
  the fork", README title/body + the "previously a full fork"
  disclaimer, `flake.nix` `description`, `overlays/amarbel-packages.nix`
  header, `gomod2nix.7.scd` examples, `bats/CLAUDE.md`, this repo's
  `CLAUDE.md`, the project memory entry.
- **Issue/RFC cross-references** — `amarbel-llc/nixpkgs RFC 0001` and
  `TODO[amarbel-llc/nixpkgs#NN]` style refs scattered through `.nix`,
  `.go`, and `.md` files across the workspace (dodder, moxy, tap,
  bats, doppelgang, the in-repo FDRs/RFCs/plans, …).

⚠ **Issue-number references may not survive verbatim.** GitHub's
issue *transfer* renumbers issues in the target repo to avoid
collisions. So `#37` here may become `#N` in igloo. Every
`amarbel-llc/nixpkgs#NN` reference in code/docs is therefore a
*potentially-renumbered* link, not just a renamed one. This is the
messiest part of the cutover and has no clean mechanical fix — the
chosen approach is transfer → capture the old→new number map → rewrite
refs from it (see § Resolved decisions and the Class 2/3 mechanism).

## Migration mechanism

### Class 1: ast-grep (confirmed working)

Nix is a supported ast-grep grammar (verified). The rewrite is a
string-literal swap, which ast-grep applies only to the exact node —
comment-safe and pinned-rev-safe. Dry-run against `moxy/flake.nix` and
`clown/flake.nix`:

```
pattern:  "github:amarbel-llc/nixpkgs"
rewrite:  "github:amarbel-llc/igloo"
lang:     nix
```

…rewrote `nixpkgs.url = "github:amarbel-llc/nixpkgs";` → `…/igloo;`
and left clown's three pinned inputs and all surrounding comments
untouched. This is preferable to `sed` precisely because it will not
touch the Class-3 prose that happens to contain the same substring.

### Wiring into `eng/justfile`'s `update-nix` tree

The existing `update-nix-repos` recipe is already the right skeleton:
it walks repos in DAG order (`_compute-repo-update-order`), refuses
dirty trees, edits the flake, runs `nix flake update`, verifies via
the repo's own `just` in its devshell, then commits + pushes — halting
on first failure. The igloo cutover is structurally identical, with
two substitutions:

- the `sed`-the-`nixpkgs-master`-SHA step → the ast-grep URL rewrite
  above (`mcp arboretum.rewrite`, or `ast-grep` directly in the
  recipe);
- `nix flake update` → `nix flake update nixpkgs` (re-resolve just the
  renamed input against igloo).

Proposed one-shot recipe (lives next to `update-nix-repos`, marked for
deletion after cutover per the workaround-recipe convention):

```just
# ONE-TIME: cut every repos/* `nixpkgs` flake input over from the old
# fork URL to amarbel-llc/igloo, then re-lock against the renamed repo.
# Mirrors update-nix-repos (DAG order, refuse-if-dirty, verify-via-just,
# commit+push) but swaps the SHA-sed for an ast-grep URL rewrite and
# scopes `nix flake update` to the `nixpkgs` input.
# PRECONDITION: amarbel-llc/igloo must already be published.
# DELETE after the cutover lands. Tracks amarbel-llc/igloo#<N>.
[group("migration")]
_migrate-igloo-rename:
  #!/usr/bin/env bash
  set -euo pipefail
  just _compute-repo-update-order | while read -r dir; do
    name="$(basename "$dir")"
    cd "$dir"
    # refuse dirty tree (same guard as update-nix-repos)
    if ! git diff --quiet HEAD; then
      gum log --level error "$name: dirty tree — refusing"; exit 1
    fi
    # skip repos with no amarbel nixpkgs input
    if ! grep -q '"github:amarbel-llc/nixpkgs"' flake.nix 2>/dev/null; then
      gum log --level info "$name: no igloo-bound input — skipping"; cd -; continue
    fi
    # refuse if a pinned-rev fork URL is still present (Class 2 — manual)
    if grep -qE '"github:amarbel-llc/nixpkgs/[0-9a-f]{7,}"' flake.nix; then
      gum log --level error "$name: pinned-rev fork URL present — handle by hand first"; exit 1
    fi
    ast-grep run -U -l nix \
      -p '"github:amarbel-llc/nixpkgs"' \
      -r '"github:amarbel-llc/igloo"' flake.nix
    nix flake update nixpkgs
    # verify via the repo's own default lane, then commit + push
    if [[ -f justfile ]]; then just; else nix build; fi
    git add flake.nix flake.lock
    git commit -m "chore: cut nixpkgs input over to amarbel-llc/igloo"
    git push
    cd -
  done
```

`piggy` carries the `nixpkgs` input twice — its own `flake.nix` and the
vendored `vendor/pivy/flake.nix`. **Decision: handle the vendored flake
out of band**, not in the automated sweep — vendored trees can be
regenerated from upstream, so an in-place rewrite could be clobbered.
The recipe's `flake.nix`-only rewrite covers piggy's primary input; the
vendored one is cut over by hand. A followup to collapse that duplicate
input entirely is filed as **piggy#124**.

### Class 2 + Class 3: by hand / by regex, not ast-grep

ast-grep is out for both, confirmed empirically: searching the bare
token `amarbel-llc/nixpkgs` *and* the comment pattern `# $A` (lang nix)
against a file that carries the token **in comments** both returned
zero matches. ast-grep's pattern engine only matches parsed code nodes;
comment bodies are opaque trivia. So:

- **Class 2** (pinned-rev inputs): hand-edited in clown, re-pointed at
  `github:NixOS/nixpkgs/<sha>`.
- **Class 3** (prose + issue refs): a scripted `rg`/`sed` capture-group
  pass, driven by the old→new issue-number map from the transfer.
  Substring-in-comment + renumber is a regex job, not an AST job.

### Issue migration

Prefer `gh issue transfer <n> amarbel-llc/igloo` over manual copy:
it preserves the thread (comments, authors, timeline) and leaves a
redirect on the old issue. Caveats: issues transfer one at a time
(script a loop over `gh issue list --json number`), the source repo
must still exist at transfer time, and **numbers may be reassigned**
in igloo. Do the transfer *before* archiving the old repo and *before*
the Class-3 issue-reference sweep, so the sweep can map old→new
numbers from the transfer output.

## Rollout

Ordered; each step is independently committable.

0. **File the tracking issue** on `amarbel-llc/nixpkgs` (it transfers
   into igloo with the rest). Fill in the `tracks:` frontmatter.
1. **Create `amarbel-llc/igloo`**; push the current tree as a single
   squashed root commit, and add the README + AGENTS.md pointer to the
   archived old repo for fork-era history.
2. **In-repo terminology sweep** (Class 3, igloo side): README,
   `flake.nix` description, `CLAUDE.md`, `overlays/amarbel-packages.nix`
   header, `gomod2nix.7.scd` examples, the FDR/RFC/plan cross-refs.
   Drop the "previously a full fork" framing entirely.
3. **Transfer issues** old → igloo; capture the old→new number map.
4. **Class 2 fixups** in clown — re-point the three pinned inputs (and
   `zz-pocs/0002`) at `github:NixOS/nixpkgs/<sha>`. Commit per repo.
5. **Class 1 sweep** — run `_migrate-igloo-rename` (the bulk cutover;
   verifies each repo green before pushing). Hand-cut piggy's
   `vendor/pivy/flake.nix` separately (see piggy#124).
6. **Class 3 cross-repo sweep** — terminology + issue-reference
   rewrites in sibling repos, applying the number map from step 3.
   Non-mechanical; do by hand or with a number-map-aware script.
7. **Update workspace memory** (`github_issue_create_tool_choice.md`
   and any igloo-relevant entries) and `eng`-level docs that name the
   fork.
8. **Archive `amarbel-llc/nixpkgs`** once nothing references it
   (`rg 'amarbel-llc/nixpkgs'` across `~/eng/repos` returns only
   historical/plan mentions).
9. **Delete `_migrate-igloo-rename`** from `eng/justfile`.

## Resolved decisions

1. **Issue-number references → transfer + rewrite.** `gh issue
   transfer` each issue, capture the old→new number map, then rewrite
   every `amarbel-llc/nixpkgs#NN` ref from that map. Most correct end
   state; the rewrite is a scripted regex pass (ast-grep can't touch
   comments — verified above).
2. **Old repo → archive, not delete.** Keeps the fork-era git history
   and the issue-transfer redirects alive at zero cost, and is the
   backstop for any reference the sweep misses.
3. **Fresh root → squash to one commit.** Cleanest start; the dropped
   gomod2nix/bridge history is preserved in the archived old repo, with
   a README + AGENTS.md pointer in igloo for anyone who needs it.
4. **`piggy/vendor/pivy` → handle separately.** The vendored flake is
   cut over by hand (vendored trees may be regenerated and clobber an
   in-place rewrite). Followup to collapse the duplicate input filed as
   piggy#124.

## References

- README (current self-description): `README.md`
- Consumer inventory: `rg 'github:amarbel-llc/nixpkgs' ~/eng/repos`
- Cascade recipe this reuses: `~/eng/justfile` → `update-nix-repos`,
  `bump-nixpkgs`, `_compute-repo-update-order`
- ast-grep rewrite verified via `arboretum.rewrite` (dry-run) on
  `moxy/flake.nix`, `clown/flake.nix`
