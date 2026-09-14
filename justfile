# vim: ft=just

default: build test lint

build: build-eval

# eval-check changed packages (fast — catches nix errors without building)
build-eval:
    #!/usr/bin/env bash
    set -euo pipefail

    changed_pkgs=$(
        git diff --name-only master -- pkgs/by-name/ \
        | sed -n 's|^pkgs/by-name/[a-z0-9_-]\{2\}/\([^/]\+\)/.*|\1|p' \
        | sort -u
    )

    # Overlay pins: extract package names from changed pin files
    overlay_pkgs=$(
        git diff --name-only master -- overlays/pins/ \
        | sed -n 's|^overlays/pins/\(.*\)\.nix$|\1|p' \
        | sort -u
    )

    failed=()

    # amarbel-packages overlay: always check these (not discoverable by filename).
    # Checked separately since some are functions, not derivations.
    amarbel_pkgs=(fetchGgufModel buildBunBinary buildBunBinaries buildZxScript buildZxScriptFromFile eslintCache fetchBunDeps mkBunDerivation writeBunApplication writeBunScriptBin gomod2nix gomod2nix-man update-zx-deps)
    for pkg in "${amarbel_pkgs[@]}"; do
        gum log --level info "evaluating $pkg"
        if nix eval "path:.#$pkg" > /dev/null 2>&1; then
            gum log --level info "$pkg ok"
        else
            gum log --level error "$pkg failed to evaluate"
            failed+=("$pkg")
        fi
    done

    all_pkgs=$(echo -e "${changed_pkgs}\n${overlay_pkgs}" | { grep -v '^$' || true; } | sort -u)

    if [[ -z "$all_pkgs" ]]; then
        if [[ ${#failed[@]} -gt 0 ]]; then
            gum log --level error "failed packages:" "${failed[@]}"
            exit 1
        fi
        gum log --level info "no changed packages or overlays detected"
        exit 0
    fi

    gum log --level info "checking packages:" $all_pkgs

    for pkg in $all_pkgs; do
        gum log --level info "evaluating $pkg"
        if nix eval --json "path:.#$pkg.version" > /dev/null 2>&1 \
           || nix eval --json "path:.#$pkg.name" > /dev/null 2>&1; then
            gum log --level info "$pkg ok"
        else
            gum log --level error "$pkg failed to evaluate"
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        gum log --level error "failed packages:" "${failed[@]}"
        exit 1
    fi

    gum log --level info "all changed packages evaluated successfully"

test: test-gomod2nix test-gomod2nix-merge-annotation test-go-toolchain test-godyn

# [test] Build every gomod2nix build-support eval-test fixture. These pin
# buildGoApplication / mkGoEnv / mkGoPkgs behavior (version resolution,
# pwd validation, the goFlakeInputs merge, the producer-side filter) that
# build-eval's eval pass does not exercise. Wired into `default` so a
# regression fails the merge hook instead of waiting for someone to run
# the per-file recipe by hand.
#
# build every gomod2nix build-support eval-test fixture
[group: 'test']
test-gomod2nix:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=()
    for f in pkgs/build-support/gomod2nix/*-test.nix; do
        gum log --level info "building $f"
        if NIXPKGS_ALLOW_UNFREE=1 nix-build --no-out-link "$f"; then
            gum log --level info "$f ok"
        else
            gum log --level error "$f failed"
            failed+=("$f")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        gum log --level error "failed eval-tests:" "${failed[@]}"
        exit 1
    fi
    gum log --level info "all gomod2nix eval-tests passed"

# [test] Negative test for the goFlakeInputs bridge failure annotation
# (igloo#55): build a fixture whose merged-go.mod IFD is EXPECTED to fail,
# and assert the annotated context (offending module + provenance + the
# passthru.mergedGoMod pointer) reached stderr instead of a bare `go mod
# edit` error. Kept out of the success-only test-gomod2nix glob because its
# build must fail; wired into `default` alongside it.
#
# assert the goFlakeInputs bridge failure annotation reaches stderr
[group: 'test']
test-gomod2nix-merge-annotation:
    #!/usr/bin/env bash
    set -uo pipefail
    fixture=pkgs/build-support/gomod2nix/merge-failure-annotation-fixture.nix
    err=$(mktemp)
    trap 'rm -f "$err"' EXIT
    if NIXPKGS_ALLOW_UNFREE=1 nix-build --no-out-link "$fixture" 2>"$err"; then
        gum log --level error "expected the merged-go.mod build to FAIL, but it succeeded"
        exit 1
    fi
    if grep -q "gomod2nix goFlakeInputs bridge: 'go mod edit" "$err" \
        && grep -q "inspect the merged go.mod:" "$err"; then
        gum log --level info "bridge failure annotation present"
    else
        gum log --level error "bridge failure annotation missing from failure output:"
        cat "$err"
        exit 1
    fi

# [test] Eval-test the go-toolchain overlay (go-toolchain(7)): registry-driven
# newest resolution, per-version coexistence, and the mkGoToolchain bundle —
# WITHOUT compiling a Go toolchain (the compiler build is kept off the gate;
# see go-toolchain(7) § CACHING). Wired into `default` so a regression in the
# registry / alias wiring fails the merge hook.
#
# eval-test the go-toolchain overlay (registry + mkGoToolchain bundle)
[group: 'test']
test-go-toolchain:
    NIXPKGS_ALLOW_UNFREE=1 nix-build --no-out-link pkgs/development/compilers/go-toolchain/go-toolchain-test.nix

# [test] Build every godyn flake check (checks.<system>.godyn-*: build, embed,
# ldflags, cross-module, buildGoAuto, tests, vet, lint, postInstall fixtures).
# `just` does not run `nix flake check`, so without this a godyn regression would
# pass the merge hook. The names come from the flake, so a new godyn-* check joins
# the gate automatically. x86_64-linux only: godyn is unvalidated elsewhere
# (igloo#33).
#
# build every godyn flake check
[group: 'test']
test-godyn:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
    if [[ "$system" != x86_64-linux ]]; then
        gum log --level warn "skipping godyn checks on $system (godyn validated on x86_64-linux only, igloo#33)"
        exit 0
    fi
    mapfile -t names < <(nix eval --raw ".#checks.${system}" \
        --apply 'cs: builtins.concatStringsSep "\n" (builtins.filter (n: builtins.substring 0 6 n == "godyn-") (builtins.attrNames cs))')
    # an empty list would make `nix build` fall back to the flake's default package
    if [[ ${#names[@]} -eq 0 ]]; then
        gum log --level error "no checks.${system}.godyn-* found — the name query is broken"
        exit 1
    fi
    gum log --level info "building ${#names[@]} godyn checks"
    nix build --no-link --print-build-logs "${names[@]/#/.#checks.${system}.}"

lint: lint-fmt lint-worktree

# read-only formatting gate via checks.formatting (sandboxed)
lint-fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
    nix build ".#checks.${system}.formatting" --no-link --print-build-logs

# run the impure git-state linters against the live working tree
lint-worktree:
    #!/usr/bin/env bash
    set -euo pipefail
    cfg=$(nix build --no-link --print-out-paths '.#conformist-impure-config')
    nix run '.#conformist' -- check --config-file "$cfg" --tree-root .

codemod-fmt: codemod-fmt-nix

# format all nix files (write mode)
codemod-fmt-nix:
    nix fmt

# build changed packages (slow — full nix build)
[group: 'explore']
explore-build-changed:
    #!/usr/bin/env bash
    set -euo pipefail

    changed_pkgs=$(
        git diff --name-only master -- pkgs/by-name/ \
        | sed -n 's|^pkgs/by-name/[a-z0-9_-]\{2\}/\([^/]\+\)/.*|\1|p' \
        | sort -u
    )

    overlay_pkgs=$(
        git diff --name-only master -- overlays/pins/ \
        | sed -n 's|^overlays/pins/\(.*\)\.nix$|\1|p' \
        | sort -u
    )

    all_pkgs=$(echo -e "${changed_pkgs}\n${overlay_pkgs}" | { grep -v '^$' || true; } | sort -u)

    if [[ -z "$all_pkgs" ]]; then
        gum log --level info "no changed packages or overlays detected"
        exit 0
    fi

    gum log --level info "building packages:" $all_pkgs

    failed=()
    for pkg in $all_pkgs; do
        gum log --level info "building $pkg"
        if NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths "path:.#$pkg"; then
            gum log --level info "$pkg ok"
        else
            gum log --level error "$pkg failed"
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        gum log --level error "failed packages:" "${failed[@]}"
        exit 1
    fi

    gum log --level info "all changed packages built successfully"

# build a specific package by attribute name
[group: 'explore']
explore-build pkg:
    NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths "path:.#{{ pkg }}"

# [explore] Run an eval-time test fixture (nix-build a standalone .nix file).
# Used for the gomod2nix internals tests that aren't wired as flake outputs:
#   just explore-nix-build pkgs/build-support/gomod2nix/mk-go-pkgs-test.nix
#   just explore-nix-build pkgs/build-support/gomod2nix/pwd-validation-test.nix
#   just explore-nix-build pkgs/build-support/gomod2nix/internals-merge-test.nix
#
# run an eval-time test fixture (nix-build a standalone .nix file)
[group: 'explore']
explore-nix-build path:
    NIXPKGS_ALLOW_UNFREE=1 nix-build --no-out-link "{{ path }}"

# [explore] Warm-cache POC for the buildGoLint lane (spinclass#294, FDR 0006).
# git-archives two salted copies of a spinclass checkout's HEAD into .tmp,
# shows mkGoLintCacheEnv's drvPath is identical for both, prebuilds the seeds,
# then times golangci-lint cold vs. warm-seeded inside the sandbox. Full logs:
# .tmp/warm-cache-poc/. nix-build rather than nix build: getFlake of the
# sibling checkout is impure.
#
# time cold vs warm-seeded golangci-lint against a real bridged module
[group: 'explore']
explore-lint-warm-cache spinclass=(env_var('HOME') + "/eng/repos/spinclass"):
    #!/usr/bin/env bash
    set -euo pipefail
    fixture=zz-pocs/gocheck-poc/warm-cache.nix
    work="$PWD/.tmp/warm-cache-poc"
    run=$(date +%s)
    nb() {
        local log="$work/$run-$1-$2.log"
        gum log --level info "building $2 (salt $1)"
        nix-build --no-out-link --show-trace "$fixture" --argstr spinclass "{{ spinclass }}" \
            --argstr tree "$work/spinclass-$run-$1" -A "$2" 2>"$log" >/dev/null \
            || { tail -n 60 "$log"; gum log --level error "nix-build $2 (salt $1) failed; full log: $log"; exit 1; }
        grep -E 'mkGoLintCacheEnv:|warm-cache-poc|buildGoCheck: seeding|Execution took|packages loading' "$log" || true
    }
    gum log --level info "lintCacheEnv drvPath per salt (must match: first-party edits must not re-key it)"
    for salt in a b; do
        tree="$work/spinclass-$run-$salt"
        mkdir -p "$tree"
        git -C "{{ spinclass }}" archive HEAD | tar -x -C "$tree"
        echo "// warm-cache-poc salt $run-$salt" >> "$tree/cmd/spinclass/main.go"
        nix-instantiate "$fixture" --argstr spinclass "{{ spinclass }}" --argstr tree "$tree" -A lintCacheEnv
    done
    nb a lintCacheEnv
    nb a realLintCacheEnv
    nb a cold
    nb a warm
    nb b warm
    nb a real-warm

# [explore] Prefetch a URL into the nix store and print its SRI hash.
# Serves the overlay-pin dev loop: overlays/pins/*.nix src bumps need a
# fetchurl hash, and sessions have no raw-shell path to nix-prefetch.
#
# prefetch a URL into the nix store and print its SRI hash
[group: 'explore']
explore-prefetch-url url:
    nix store prefetch-file --json "{{ url }}" | jq -r .hash

# [maintenance] Refresh the go-toolchain registry with an explicit Go version
# (go-toolchain(7)). Prefetches the go<version>.src.tar.gz SRI hash and appends
# a registry entry, refusing to rewrite an existing one. Serves the "pick a Go
# point release the day it ships" loop (circus#196): after `just update-go
# 1.26.6`, `pkgs.go` = 1.26.6, `pkgs.go_1_26_6` is available, and older versions
# still build.
#
# add an explicit Go version to the go-toolchain registry (single source of truth)
[group: 'maintenance']
update-go version:
    #!/usr/bin/env bash
    set -euo pipefail
    reg="pkgs/development/compilers/go-toolchain/registry.nix"
    ver="{{ version }}"
    if grep -qF "version = \"$ver\";" "$reg"; then
        gum log --level error "go $ver already in $reg — registry is append-only; not rewriting"
        exit 1
    fi
    hash=$(nix store prefetch-file --json "https://go.dev/dl/go$ver.src.tar.gz" | jq -r .hash)
    tmp=$(mktemp)
    awk -v ver="$ver" -v hash="$hash" '
        /@@GO_TOOLCHAIN_REGISTRY_END@@/ {
            printf "  { version = \"%s\"; hash = \"%s\"; }\n", ver, hash
        }
        { print }
    ' "$reg" > "$tmp"
    mv "$tmp" "$reg"
    # Normalize the inserted single-line entry to the repo's nix formatting so
    # the tree stays clean (the formatting gate expects multi-line entries).
    nix fmt "$reg" >/dev/null 2>&1 || gum log --level warn "nix fmt on $reg failed; run \`just codemod-fmt-nix\` before merging"
    gum log --level info "added go $ver ($hash) to $reg"

# [explore] Build a real godyn flake-input consumer against THIS tree's igloo.
# conformist's main package sits at the module ROOT (dir ".") and its src
# arrives as a flake-input store path — the shape that hit the 69c772a
# string-src filter regression (reported from eng). The pinned rev is the
# verified repro: fails on unfixed igloo, must succeed on a fixed one.
# Uses `.` (git+file) for the override, so commit/stage changes first.
#
# build a real godyn flake-input consumer against this tree's igloo
[group: 'explore']
explore-test-godyn rev="ccc91bed0accabf12f63abc00e583d78aa20183e":
    nix build --no-link --print-out-paths \
        "github:amarbel-llc/conformist/{{rev}}#conformist-native" \
        --override-input igloo .

# [explore] Time godyn's inner test loop (FDR 0008): build one package's
# passthru.testWith run from a flake ref of this tree (scheme git+file, the
# CLIs' choice: tracked files as in the working tree; or path, which copies
# everything incl. .tmp), twice — the first pays evaluation, graph
# derivation and any rebuilds, the second is the no-op floor — and print each
# wall-clock time plus the run's result, then the tail of the run's test.log.
# flags are test-binary flags.
#
# time the godyn inner test loop (path: flake ref, one package)
[group: 'explore']
explore-godyn-test-loop attr="godyn-derived-tests-test" dir="leaf" flags="-test.run=. -test.v" scheme="git+file":
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    nixflags=""
    for f in {{ flags }}; do nixflags+="\"$f\" "; done
    expr="(builtins.getFlake \"{{ scheme }}:$PWD\").packages.$system.{{ attr }}.passthru.testWith { dir = \"{{ dir }}\"; testFlags = [ $nixflags]; }"
    for pass in first second; do
      start=$(date +%s%N)
      out=$(nix build --impure --no-link --print-out-paths --expr "$expr")
      end=$(date +%s%N)
      ms=$(( (end - start) / 1000000 ))
      printf '%s pass: %d.%03ds  %s\n' "$pass" $(( ms / 1000 )) $(( ms % 1000 )) "$(cat "$out/result")"
    done
    du -sh --apparent-size . 2>/dev/null | sed 's/^/path: tree size: /'
    echo "--- test.log (last 20 lines) ---"
    tail -n 20 "$out/test.log"

# [explore] Run godyn's escape hatch (FDR 0008) on a package of this tree: build
# passthru.goRun { command } — an impure derivation (network allowed, never
# cached) running the command against the rendered module — and print its
# outputs: the patch against src, the resulting go.mod and gomod2nix.toml.
#
# run a go command in godyn's escape hatch and show its outputs
[group: 'explore']
explore-godyn-go-run attr="godyn-manifest-test" cmd="go mod tidy":
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    cmd={{ quote(cmd) }}
    expr="(builtins.getFlake \"path:$PWD\").packages.$system.{{ attr }}.passthru.goRun { command = $(printf '%s' "$cmd" | jq -Rs .); }"
    out=$(nix build --impure --no-link --print-out-paths --expr "$expr")
    echo "goRun output: $out"
    for f in src-listing patch go.mod gomod2nix.toml; do
      echo "--- $f ---"; cat "$out/$f"
    done

# [explore] Run the godyn-go escape hatch CLI (FDR 0008) from this tree, e.g.
#   just explore-godyn-go -A packages.x86_64-linux.godyn-manifest-test \
#     -m pkgs/build-support/godyn/tests/manifest/go.nix -- go get github.com/google/go-cmp@v0.7.0
# Rewrites the named go.nix (and applies any patch) — revert afterwards.
#
# run godyn-go (the escape hatch CLI) with the given arguments
[group: 'explore']
explore-godyn-go *args:
    nix run --impure "path:.#godyn-go" -- {{ args }}

# [explore] Run the godyn-test inner-loop CLI (FDR 0008) from this tree, e.g.
#   just explore-godyn-test -A packages.x86_64-linux.godyn-derived-tests-test leaf -- -test.v
#
# run godyn-test (the inner test loop CLI) with the given arguments
[group: 'explore']
explore-godyn-test *args:
    nix run --impure "path:.#godyn-test" -- {{ args }}

# [explore] What a path: flake ref of this checkout copies into the store (FDR
# 0008 cost question): whether .git and the git-ignored .tmp are in the copy,
# and the copy's size. godyn-go and godyn-test build from such a ref.
#
# report whether a path: flake ref of this tree copies .git and .tmp
[group: 'explore']
explore-path-ref-contents:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(nix eval --impure --raw --expr "(builtins.getFlake \"path:$PWD\").outPath")
    echo "store copy: $out"
    for d in .git .tmp; do
      if [ -e "$out/$d" ]; then echo "$d: copied"; else echo "$d: not copied"; fi
    done
    du -sh "$out" | sed 's/^/copy size: /'
    du -sh --apparent-size .tmp 2>/dev/null | sed 's/^/checkout .tmp size: /'

# [explore] Test the overlay-flake migration against amarbel-llc/maneater
# Clones into .tmp/maneater (or reuses), bumps the nixpkgs input, runs
# nix flake check + nix build .#default.
#
# test the overlay-flake migration against amarbel-llc/maneater
[group: 'explore']
explore-test-maneater:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .tmp
    target=.tmp/maneater
    if [[ -d "$target/.git" ]]; then
      gum log --level info "reusing existing $target"
      git -C "$target" fetch --quiet origin
      git -C "$target" reset --hard origin/HEAD
    else
      gum log --level info "cloning maneater into $target"
      git clone --quiet git@github.com:amarbel-llc/maneater.git "$target"
    fi

    # Override maneater's nixpkgs input to the LOCAL worktree
    # so the test exercises the in-progress overlay flake, not whatever
    # has been pushed to origin.
    local_overlay="$(pwd)"
    cd "$target"
    gum log --level info "overriding nixpkgs input to path:$local_overlay"

    gum log --level info "running nix flake check (eval-only)"
    NIXPKGS_ALLOW_UNFREE=1 nix flake check \
      --keep-going --no-build --impure \
      --override-input nixpkgs "path:$local_overlay"

# [explore] Sync a directory tree from amarbel-llc/bun via gh API.
# Used by issue #52 to seed pkgs/build-support/bun2nix/lint/ from the
# upstream lint stack. After lint is landed here, this is the paved path
# for refreshing bun.lock/bun.nix when amarbel-llc/bun regenerates them.
#   just explore-sync-bun-tree nix/bun2nix/lint pkgs/build-support/bun2nix/lint
#
# sync a directory tree from amarbel-llc/bun via the gh API
[group: 'explore']
explore-sync-bun-tree src dst ref="master":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ dst }}"
    gh api --paginate "repos/amarbel-llc/bun/contents/{{ src }}?ref={{ ref }}" \
      --jq '.[] | select(.type == "file") | .path' \
    | while read -r path; do
        rel="${path#{{ src }}/}"
        out="{{ dst }}/$rel"
        mkdir -p "$(dirname "$out")"
        gum log --level info "fetching $path"
        gh api "repos/amarbel-llc/bun/contents/$path?ref={{ ref }}" \
          --jq '.content' \
        | base64 -d > "$out"
      done
    gum log --level info "sync-bun-tree: copied {{ src }} -> {{ dst }}"

# [explore] Sync a single file from amarbel-llc/bun via gh API.
# Companion to explore-sync-bun-tree for cases where only one file is wanted
# (e.g. one ADR out of a docs/decisions tree, one script out of scripts/).
# dst is a full file path, so renames are natural:
#   just explore-sync-bun-file docs/decisions/0001-foo.md docs/decisions/0002-foo.md
#
# sync a single file from amarbel-llc/bun via the gh API
[group: 'explore']
explore-sync-bun-file src dst ref="master":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$(dirname "{{ dst }}")"
    gum log --level info "fetching {{ src }}"
    gh api "repos/amarbel-llc/bun/contents/{{ src }}?ref={{ ref }}" \
      --jq '.content' \
    | base64 -d > "{{ dst }}"
    gum log --level info "sync-bun-file: copied {{ src }} -> {{ dst }}"

# [explore] Regenerate the godyn gotest fixture's committed graphs (build + test)
# with the IN-TREE godyn-gen (built from source, so the working tree's gen is
# what's exercised). Run after changing the fixture's import structure, file
# sets, or test functions — NOT after content-only edits. Serves the igloo#32
# dev loop; the godyn-gotest-test flake check consumes the committed output.
#
# regenerate the godyn gotest fixture's committed graphs with the in-tree gen
[group: 'explore']
explore-gen-godyn-fixture:
    #!/usr/bin/env bash
    set -euo pipefail
    goStore=$(nix build --no-link --print-out-paths 'path:.#go')
    export PATH="$goStore/bin:$PATH" GOCACHE=$(mktemp -d) GOPATH=$(mktemp -d)
    gen=$(mktemp -d)/godyn-gen
    ( cd pkgs/build-support/godyn/gen && go build -o "$gen" . )
    cd pkgs/build-support/godyn/tests/gotest
    CGO_ENABLED=0 "$gen" . godyn-graph.json
    CGO_ENABLED=0 "$gen" -tests . godyn-test-graph.json
    gum log --level info "regenerated gotest fixture graphs"

# [explore] Regenerate a godyn test fixture's committed graph.json (e.g. embed-glob,
# vet) with the IN-TREE godyn-gen, so the checks exercise what the current gen
# emits. Run after changing a fixture's imports, embeds, or file set; pass cgo=1
# for a fixture with cgo packages (the default drops cgo files).
#
# regenerate a godyn fixture's graph.json with the in-tree gen
[group: 'explore']
explore-gen-godyn-graph fixture cgo="0":
    #!/usr/bin/env bash
    set -euo pipefail
    gen=$(nix build --no-link --print-out-paths '.#godyn-gen')/bin/godyn-gen
    goStore=$(nix build --no-link --print-out-paths '.#go')
    export PATH="$goStore/bin:$PATH"
    dir=pkgs/build-support/godyn/tests/{{ fixture }}
    CGO_ENABLED={{ cgo }} "$gen" "$dir" "$dir/graph.json"
    gum log --level info "regenerated $dir/graph.json"

# [explore] Refresh godyn-lint's dependencies (buildGodynLint's analyzer suite):
# bump staticcheck to latest, tidy, vet + test it, and regenerate its
# gomod2nix.toml with the in-tree gomod2nix. Needs network; run after changing
# its imports or to pick up new analyzers. From x/tools v0.50.0 unitchecker
# expects every import's vetx to carry its type data; godyn-lint declares that
# (passthru.typedVetx) and its lint lane feeds it the stdlib vetx lane (igloo#71).
#
# update godyn-lint's go.mod/go.sum/gomod2nix.toml (network)
[group: 'explore']
explore-update-godyn-lint-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    goStore=$(nix build --no-link --print-out-paths '.#go')
    g2n=$(nix build --no-link --print-out-paths '.#gomod2nix')/bin/gomod2nix
    export PATH="$goStore/bin:$PATH" GOTOOLCHAIN=local CGO_ENABLED=0
    cd pkgs/build-support/godyn/lint
    go get honnef.co/go/tools@latest golang.org/x/tools@latest
    go mod tidy
    go vet ./...
    go test ./...
    "$g2n" generate
    gum log --level info "refreshed godyn-lint deps and gomod2nix.toml"

# [explore] igloo#67 acceptance: regenerate a goFlakeInputs consumer's godyn graph
# with the in-tree `godyn-gen -gomod <its passthru.mergedGoMod>` and diff it against
# the graph the consumer produced by swapping go.mod by hand (its committed
# godyn-graph.json). The embedPatternFiles field is stripped before the diff (and
# printed). Writes only under .tmp/.
#
# diff a godyn-gen -gomod graph against a consumer's hand-swapped graph
[group: 'explore']
explore-godyn-gomod-acceptance consumer:
    #!/usr/bin/env bash
    set -euo pipefail
    work="$PWD/.tmp/godyn-gomod-acceptance"
    mkdir -p "$work"
    system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
    merged=$(nix build --no-link --print-out-paths "{{ consumer }}#packages.${system}.default.passthru.mergedGoMod")
    gen=$(nix build --no-link --print-out-paths '.#godyn-gen')/bin/godyn-gen
    goStore=$(nix build --no-link --print-out-paths '.#go')
    export PATH="$goStore/bin:$PATH" CGO_ENABLED=0
    ( cd "{{ consumer }}" && "$gen" -gomod "$merged" . "$work/graph.json" )
    jq -c '.[] | select(.embedPatternFiles) | {importPath, embedPatternFiles}' "$work/graph.json"
    jq 'map(del(.embedPatternFiles))' "$work/graph.json" > "$work/graph.stripped.json"
    if diff -u "{{ consumer }}/godyn-graph.json" "$work/graph.stripped.json"; then
        gum log --level info "identical to the hand-swapped graph (modulo embedPatternFiles)"
    else
        gum log --level error "graphs differ"
        exit 1
    fi
