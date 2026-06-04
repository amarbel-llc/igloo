# godyn-dewey — per-package builder on a real fork module (cgo + tags + bridge)

Real-world validation of the godyn per-package Go builder (see `../godyn-poc/`)
against a real fork module — dewey
(`github.com/amarbel-llc/purse-first/libs/dewey`) — exercising the three things
the toys skipped: **cgo** (dewey → `DataDog/zstd`), **build tags**, and the
**flake-input bridge** (`github.com/amarbel-llc/tommy` from its `go-pkgs` output).
Plus a dewey inlining-density measurement.

The dewey/purse-first source is a gitignored clone under
`/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany/.tmp/purse-first`
(cloned to avoid cross-worktree permission prompts); only this README + recipes
are tracked.

## Milestones

- **D0 measure** — dewey inlining density. ✅ (below)
- **D1 lockfile** — generate the godyn lockfile from purse-first's
  `gomod2nix.toml` (SRI NAR hashes) + dewey's `go.sum` (h1).
- **D2 tags** — thread build tags through `go list` + compile.
- **D3 cgo** — compile + link `internal/delta/compression_type` (zstd).
- **D4 bridge** — source tommy from its `go-pkgs` (replace → store path).
- **D5 full** — build all dewey packages (`./...`).

## Findings

### D0: dewey inlining density (go 1.26, dewey @ working tree 2026-06)

Method: `.#defererr.passthru.vendorEnv` materialised into the cloned workspace +
`GO_NO_VENDOR_CHECKS=1 GOFLAGS=-mod=vendor go build -gcflags=-m ./libs/dewey/...`
(CGO off, so `internal/delta/compression_type` → zstd fails last; the rest is
complete).

- **2,901 inlinable functions; 6,926 inlined call sites** (dewey is ~half
  dodder's 14,236).
- **Same pattern as dodder** — the fork's own generic collections dominate:

  | source | sites | kind |
  |---|---|---|
  | `collections_slice` | 814 | dewey generic container |
  | `collections_value` + `Slice[...]` + `Flag[...]` instantiations | ~640 | dewey generic containers |
  | `jen` (dave/jennifer), `lua` (gopher-lua), `types` (go/types) | ~1,010 | third-party codegen / analysis libs |
  | `errors`, `fmt`, `strings`, `atomic`, `time`, `slices`, `sync`, `bytes`, `reflect`, … | ~2,000 | stdlib |

**Interpretation.** dewey confirms the dodder result *generalizes across the
fork*: heavy reliance on generic collection types (`collections_*`) whose methods
inline pervasively into nearly every consumer. So the per-package CA cache win is
the same shape everywhere — real for high-layer edits, bounded for foundational
generic edits — and the `-gcflags=all=-l` inlining-off variant is a fork-wide
lever, not a dodder quirk.
