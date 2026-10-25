# nixedit

Byte-preserving structural edits to a `flake.nix`: splice and delete
`follows` bindings, read and pin input urls, list inputs and overrides,
classify and widen the `outputs` signature, and enforce the opt-in
canonical form of the `inputs` block. A shallow Nix PEG (`nix.peg`,
embedded; parsed with langlang) locates the `inputs` attrset and its
binding keys and skips every value opaquely, so anything the grammar
cannot parse is refused (`ErrUnparseable`) rather than rewritten.

Lifted verbatim from doppelgang's `internal/0/nixedit` on 2026-10-25
(igloo#64, operator decision: copy now, FDR after; the donor side is
doppelgang#35). Module path
`code.linenisgreat.com/igloo/pkgs/build-support/nixedit`; the CLI is
`cmd/nixedit` (see its package comment for the subcommands). The package's
tests came with it and are the acceptance that behaviour is unchanged.

Not yet done, each waiting on a decision or on the build lock lifting:

- the Nix wiring (a `go.nix` manifest needs langlang's vendor hash, which
  needs network; then `buildGoAuto` plus a `nixedit-test` check running the
  package tests and a `nixedit-man` page);
- the final module path (igloo's remote is the owner-less vanity URL, and
  whether the forge serves `go-import` meta tags for it is unverified; the
  path above is the form Go accepts for a module in a repository
  subdirectory);
- the `# doppelgang: <directive>` comment convention and `ErrUnparseable`'s
  message still name doppelgang; renaming them is a behaviour change for
  the donor's flakes and belongs to the FDR.
