---
status: proposed
date: 2026-10-25
promotion-criteria: >-
  proposed → experimental: igloo builds the package and runs its ported
  tests as a flake check (`nixedit-test`) and ships the CLI (`nixedit`)
  and a manpage; doppelgang consumes the igloo module through go.nix
  `flakeInputs` (igloo's `go-pkgs`, see Dependencies) and deletes its copy
  (doppelgang#35).

  experimental → testing: conformist (or another fleet tool) uses the
  package or CLI for a flake.nix edit it previously did by hand or with
  its own parser.
---

# nixedit: structural flake.nix editing as an igloo Go package and CLI

## Problem Statement

Fleet tooling keeps needing small, exact edits to a `flake.nix`: splice a
`follows` binding, pin an input's url, widen a closed `outputs` signature,
prune a dead override, keep the `inputs` block in a canonical shape. Each
tool that needed one grew its own parser (doppelgang's `internal/0/nixedit`,
conformist's `flakeparse`), and doppelgang's, the most complete, was
internal to a leaf repository that conformist and one-off correction tools
could not depend on without a cycle. igloo is the DAG root every fleet repo
already reaches, so the editor moves here (igloo#64, eng FDR 0015's
umbrella; the operator's decision of 2026-10-25: copy now, record after).

## Interface

- **Package** `code.linenisgreat.com/igloo/pkgs/build-support/nixedit`
  (module at `pkgs/build-support/nixedit`, the subdirectory form Go
  accepts; kept on the operator's call of 2026-10-25). A byte-for-byte
  copy of doppelgang's package: `Apply`, `DeleteBindings`, `Overrides`,
  `InputNames`, `InputURL`, `SetInputURL`, `OutputsFormals`,
  `WidenOutputsFormals`, `CanonicalForm`, `CanonicalFormFixTargets`,
  `MigrateLegacySentinel`, and `ErrUnparseable`. Every edit preserves the
  rest of the file byte for byte and refuses, with `ErrUnparseable`, any
  file the shallow grammar cannot parse, so a caller falls back to
  report-only instead of corrupting a flake.
- **Grammar** `nix.peg`, embedded in the package (`//go:embed`) and parsed
  with langlang's runtime matcher: it models the top-level attribute set,
  binding keys and the `inputs` block structurally and skips every value
  opaquely, which is what makes the edits safe and the grammar small.
- **CLI** `nixedit SUBCOMMAND [-w] FLAKE [ARGS…]` (`cmd/nixedit`), one
  subcommand per operation (`apply`, `delete`, `overrides`, `input-names`,
  `input-url`, `set-input-url`, `outputs-formals`, `widen-outputs`,
  `canonical`, `canonical-fix`); `-w` rewrites the file in place, without
  it the result is printed; exit status 2 is "not parseable, nothing
  changed".
- **Dependencies**: langlang only (`github.com/clarete/langlang/go`), a
  registry require in nixedit's go.nix. **Reversed on 2026-10-26
  (operator):** doppelgang consumes the igloo module through RFC 0001
  `flakeInputs`, not as a plain go.mod dependency. The #64 shape needed
  `go get` from the forge — a tracked go.mod in the subdirectory, a
  go-import vanity answer, and native go tooling outside nix — which FDR
  0007/0008 forbid and RFC 0003 (go.nix is a MUST) made explicit the same
  day; a go.nix module cannot track a hand-written go.mod. So igloo
  publishes `packages.<system>.go-pkgs` for nixedit (`mkGoPkgs` with the
  manifest and `subPath = "pkgs/build-support/nixedit"`), and doppelgang,
  whose nixpkgs input already is igloo, bridges it with
  `flakeInputs."code.linenisgreat.com/igloo/pkgs/build-support/nixedit" =
  { input = "<its igloo input>"; subPath = "pkgs/build-support/nixedit"; }`.
  One flake edge, the one that already exists.

## Examples

    nixedit apply -w flake.nix 'inputs.igloo.inputs.nixpkgs-master.follows = "nixpkgs-master"'
    nixedit set-input-url -w flake.nix nixpkgs-master github:NixOS/nixpkgs/<rev>
    nixedit widen-outputs flake.nix          # prints the file with `...` added to a closed outputs set
    nixedit canonical flake.nix              # enabled=true legacy-sentinel=false scattered=igloo
    nixedit canonical-fix -w flake.nix

## Limitations

- Shallow by design: attribute names with interpolation, an `inputs` value
  that is a compound expression (`let … in { … }`), or a file whose
  bindings before `inputs` the grammar cannot skip, all yield
  `ErrUnparseable` rather than an edit.
- The opt-in comment convention is still spelled `# doppelgang: <directive>`
  (and the legacy `# canonical-form`), and the error text names
  doppelgang: renaming them changes behaviour for the donor's flakes and is
  deferred until doppelgang has cut over.
- Not yet built in igloo: the Nix wiring (a go.nix manifest, which needs
  langlang's vendor hash; a `nixedit-test` check running the ported tests;
  `nixedit-man`) is the promotion criterion above. Whether the forge serves
  `go-import` meta for igloo's owner-less vanity URL is unverified;
  consumers reach the module through the flake input (RFC 0001's bridge)
  regardless.
- conformist's narrower `flakeparse` is not merged in; subsumption is a
  later decision once this package has a consumer.

## More Information

- igloo#64 (this lift), doppelgang#35 (the donor-side removal), eng FDR 0015
  (conformist profile-cache-delivered linters, the umbrella).
- `pkgs/build-support/nixedit/README.md` for the copy's provenance and the
  pending wiring; doppelgang's FDR 0007 for the canonical-form rules the
  package enforces.
