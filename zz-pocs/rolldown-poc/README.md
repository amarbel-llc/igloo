# rolldown-poc

Proof-of-concept demonstrating that the fork's `bun2nix` build-support library
can package an npm-style project whose dependency graph includes native Rust
binaries distributed as optional platform-specific packages, using a realistic
rolldown configuration adapted from `~/eng/repos/chrest/extension`.

## What it proves

- A multi-entry `rolldown` config (two entry points: `main.js` → cjs,
  `options.js` → iife) with a custom inline plugin (`constsPlugin` resolving
  virtual `consts:` imports) runs inside a Nix sandbox via Bun.
- Runtime deps with their own transitive graphs (`async-mutex`,
  `error-stack-parser-es`) are bundled into the output.
- Environment variables (`BROWSER_TYPE`) reach the `rolldown.config.mjs` at
  build time.
- The full set of `@rolldown/binding-*` native bindings is captured
  deterministically in the FOD via `fetchBunDeps`.
- At Nix build time, Bun populates `node_modules/` with the host-matching
  binding and `bun run build` invokes rolldown to produce
  `dist-chrome/{main,options}.js`.
- No custom `rolldown2nix` / `buildNpmPackage` wrapper is required.

See GitHub issue #8 for the motivating context.

## Layout

- `src/*.js` — five-file JS module graph copied from `chrest/extension/src/`
  (main, lib, items, options, routes)
- `rolldown.config.mjs` — multi-entry config with `constsPlugin`, copied
  verbatim from `chrest/extension`
- `package.json` — bun-oriented; `rolldown` as devDependency, `async-mutex`
  and `error-stack-parser-es` as runtime deps (matches chrest's deps)
- `bun.lock` / `bun.nix` — generated lockfile and its Nix-consumable form
- `flake.nix` / `default.nix` — Nix entry points
- `justfile` — `explore`-group recipes for rerunning each step

## Running the PoC

```sh
just nix-build
# → result/dist-chrome/{main.js,options.js}
```

To re-run the host-side sanity check (regenerate `bun.lock` and bundle
locally):

```sh
just bootstrap   # bun install
just host-build  # BROWSER_TYPE=chrome bun run build
```

To regenerate `bun.nix` after dependency changes:

```sh
just regen-bun-nix
```

## Known caveats

1. **Per-machine absolute path.** `flake.nix` pins `inputs.nixpkgs.url` to an
   absolute path of this fork's worktree
   (`/home/sasha/eng/repos/nixpkgs/.worktrees/plain-linden`).
   - Why: relative `path:../..` gets re-rooted to the `/nix/store` copy of the
     flake at eval time (resolves to `/nix/`, which is forbidden in pure mode).
   - Consequence: running the PoC on another machine or a different worktree
     requires editing that URL.

2. **External `bun2nix` CLI flake input.** `flake.nix` declares
   `nix-community/bun2nix` as an input to get the `bun2nix` CLI binary into
   the devShell (needed to regenerate `bun.nix`). The Nix-side builder uses
   `pkgs.fetchBunDeps` directly, which is wired through the overlay.

3. **Rolldown version drift.** `package.json` declares `^1.0.0-beta.8`
   (matching chrest). At bun install time, this resolved to `1.0.0-rc.17` —
   chrest's `package-lock.json` happens to pin `1.0.0-rc.9`. Both are valid
   resolutions of the same range; the PoC exercises bun2nix against the
   latest matching rolldown, not the pinned one.

4. **BROWSER_TYPE=chrome only.** `default.nix` hardcodes `BROWSER_TYPE=chrome`
   for the Nix build. chrest's real build runs the same config twice (once
   per browser). Adding firefox as a second Nix output would be a small
   extension.

5. **Rolldown output only.** The PoC skips the non-rolldown parts of chrest's
   build (manifest assembly via `jq`, copying `assets/*` into `dist-*/`,
   zipping `dist-*.zip`). Including those wouldn't add anything to the
   "bun2nix handles rolldown" claim.

6. **Expected: `error (ignored): NAR hash mismatch` on every invocation.**
   You will see a warning like this on each `nix develop` / `nix build`:

   ```
   error (ignored): NAR hash mismatch in input
     'path:/home/.../plain-linden?narHash=sha256-AAA='
     expected 'sha256-BBB=' but got 'sha256-AAA='
   ```

   It is **not a build failure**. Nix prints it, marks it `(ignored)`, and
   proceeds with the freshly computed hash. Output is correct.

   **Why it happens.** The PoC is a flake whose `nixpkgs` input is
   `path:/abs/to/plain-linden` — a live, mutating git worktree. Every run of
   `bun install` / `bun2nix -o bun.nix` / editing a tracked file changes that
   path's NAR hash. Nix's per-user fetcher cache
   (`~/.cache/nix/fetcher-cache-v4.sqlite`) holds a mapping from the URL to a
   previous hash; on the next invocation, the freshly computed hash differs
   from the cached one, and Nix warns before using the fresh value.

   **Why it's safe here.** Verified three ways: (a) build outputs change as
   source changes (e.g., widening from minimal → chrest config produced a
   32.6 kB `main.js` vs. the prior 110 B `bundle.js` — stale cache would have
   re-served the old output); (b) the PoC uses `pkgs.mkBunDerivation`, which
   requires commit `ef5d7e3086cf`'s overlay fix — a stale pre-fix cache would
   have thrown at `pkgs.fetchBunDeps`; (c) content-addressed store paths
   differ across runs, which only happens when Nix actually ran the build
   with the new content.

   **Why we haven't "fixed" it.** The warning is a symptom of an intentional
   design choice: a mutable `path:` flake input pointed at the local
   worktree. The alternative — restructuring the PoC as a non-flake
   `default.nix` that does `import ../.. { }` directly — would eliminate the
   warning by bypassing flake narHash tracking entirely. We chose to keep
   the current flake-based invocation for convenience; the warning is a
   flake-harness artifact, not a statement about the bun2nix-for-rolldown
   integration we're exercising.
