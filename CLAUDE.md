# igloo

This is `amarbel-llc/igloo`, a personal Nix overlay flake (it began as a
fork of nixpkgs and was reduced to an overlay before being renamed). The
`origin` remote points at `git@github.com:amarbel-llc/igloo.git`. It
consumes upstream nixpkgs as a flake input (`nixpkgs-master`), not as a git
remote. The pre-rename fork-era git history lives in the archived
`amarbel-llc/nixpkgs` repository.

## GitHub tools

`get-hubbed`'s default `repo_owner_name` resolves to
`<gh-authenticated-user>/<gh-default-name>` (i.e. `friedenberg/igloo`),
which does not exist. Always pass `repo_owner_name: "amarbel-llc/igloo"`
explicitly when calling `get-hubbed_issue-get`, `get-hubbed_issue-list`,
`get-hubbed_issue-comment`, `get-hubbed_issue-create`, etc.
