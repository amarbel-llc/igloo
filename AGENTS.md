# igloo

This is `amarbel-llc/igloo`, a personal Nix overlay flake (it began as a
fork of nixpkgs and was reduced to an overlay before being renamed). The
`origin` remote points at the Forgejo instance,
`ssh://git@code.linenisgreat.com/igloo.git`; `amarbel-llc/igloo` on GitHub
is a read-only mirror. It consumes upstream nixpkgs as a flake input
(`nixpkgs-master`), not as a git remote. The pre-rename fork-era git history
lives in the archived `amarbel-llc/nixpkgs` repository.

## Forge tools

Issues live on the Forgejo instance, not on the GitHub mirror (GitHub's
issue endpoints answer 404). The ownerless remote URL does not resolve an
owner for `smith`, so always pass `host: "code.linenisgreat.com"` and
`repo: "linenisgreat/igloo"` explicitly to the `smith_issue-*`,
`smith_repo-*` and `smith_pr-*` tools (`forge.starbrandshoes.com` is the
same instance). New issues go through the `eng:file-issue` graph.
