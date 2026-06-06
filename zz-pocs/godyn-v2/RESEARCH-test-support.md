# Research: per-package `go test` support for godyn

Status: **research / design** (no implementation). Tracks task #44 / the godyn(7)
LIMITATIONS gap ("godyn is build-only; use `go test` / buildGoApplication for
tests"). Goal: run `go test` through godyn's one-CA-derivation-per-package model so
nix's merkle-delta extends to tests — **only the changed cone's tests re-run**,
cached + parallelised, instead of `go test ./...`'s whole-module rerun.

All "ground truth" below is **empirically observed** (go 1.26.3, `go list -test
-json` + `go test -x -c` on a 1-pkg module with in-package + external tests); the
"godyn mapping" is **proposed design**, not yet built.

## Ground truth — what `go test` actually does

### `go list -test -json ./pkg` synthesizes four packages

| ImportPath | Name | GoFiles | role |
|---|---|---|---|
| `pkg` | pkg | foo.go | the normal (non-test) build |
| `pkg [pkg.test]` | pkg | foo.go **+ foo_test.go** | **test variant** — package recompiled with its in-package `_test.go` |
| `pkg_test [pkg.test]` | pkg_test | foo_ext_test.go | **external test pkg** — imports the *test variant* |
| `pkg.test` | main | *(generated `_testmain.go`, in the build cache)* | **testmain** — the runner |

`ForTest` ties the variant/external/testmain back to `pkg`. The test closure is a
**superset** of the build closure (adds `testing`, `testing/internal/testdeps`, and
any test-only imports).

### The exact toolchain commands (`go test -x -c`)

```
[1] compile -o _pkg_.a -p example.com/gtp/pkg     -importcfg ic -pack foo.go foo_test.go   # test variant
[3] compile -o _pkg_.a -p example.com/gtp/pkg_test -importcfg ic -pack foo_ext_test.go      # external (imports [1])
[5] compile -o _pkg_.a -p main                     -importcfg ic -pack _testmain.go          # testmain (imports [1]+[3]+testing+testdeps+os)
[6] link    -o pkg.test -importcfg ic.link -buildmode=exe -X testing.testBinary=1 -extld=cc _pkg_.a
    ./pkg.test            # run -> exit 0 = pass
```

(`go vet` runs between compiles by default — orthogonal to test execution, skippable.)

### The generated `_testmain.go` (a fillable template)

```go
package main
import ( "os"; "testing"; "testing/internal/testdeps"
         _test "example.com/gtp/pkg"; _xtest "example.com/gtp/pkg_test" )
var tests = []testing.InternalTest{ {"TestAdd", _test.TestAdd}, {"TestAddExt", _xtest.TestAddExt} }
var benchmarks = []testing.InternalBenchmark{ {"BenchmarkAdd", _test.BenchmarkAdd} }
var fuzzTargets = []testing.InternalFuzzTarget{}
var examples = []testing.InternalExample{}
func init() { testdeps.ModulePath = "example.com/gtp"; testdeps.ImportPath = "example.com/gtp/pkg" }
func main() { os.Exit(testing.MainStart(testdeps.TestDeps{}, tests, benchmarks, fuzzTargets, examples).Run()) }
```

The `tests`/`benchmarks`/`fuzzTargets`/`examples` slices are filled from the `Test*`
/ `Benchmark*` / `Fuzz*` / `Example*` functions discovered across the in-package and
external test files (with their signatures). `TestMain` and example `// Output:`
checks are handled by variations of this same template.

## Proposed godyn mapping — five derivations per tested package

For a package P with tests, in addition to (or instead of) P's normal compile:

1. **test-variant compile** `godyn-test-compile-<P>` — P's GoFiles **+** TestGoFiles,
   `-p <P>`, importcfg = P's deps + test imports. (Mirrors godyn's existing pure/cgo
   compile, just with the extra source files; cgo packages stay on the cgo path.)
2. **external-test compile** `godyn-test-compile-<P>_test` — XTestGoFiles, `-p <P>_test`,
   importcfg references the **test-variant** archive from (1) (not P's normal archive)
   + XTestImports.
3. **testmain compile** `godyn-test-main-<P>` — `_testmain.go`, `-p main`, importcfg =
   (1) + (2) + testing + testdeps + os.
4. **link** `godyn-test-link-<P>` — link (3) → the `<P>.test` binary, `-X
   testing.testBinary=1`, `-extld=cc` when cgo.
5. **run** `godyn-test-<P>` — execute `<P>.test` in the derivation; exit 0 ⇒ build
   succeeds (= tests pass). `$out` = captured output (optionally piped through `go
   tool test2json` for structured results).

A `go test ./...` equivalent = a manifest derivation depending on every package's
`godyn-test-<P>`; building it runs them all — **nix parallelises and caches**.

### The payoff (why this beats `go test ./...` and buildGoModule `doCheck`)

`go test ./...` and buildGoModule's `doCheck` both re-run the **whole module** on any
change. With godyn, each `godyn-test-<P>` is content-addressed on P's test-variant +
its dep closure, so nix **re-runs only the test binaries whose package or transitive
deps changed** (the merkle-delta), in parallel, and **caches passing results**. Edit
one leaf → its test (and dependents') re-run; everything else is a cache hit. This is
the godyn incremental-edit win extended to the test loop — a capability bga /
buildGoModule structurally cannot offer.

## Testmain generation — capture vs replicate

The `_testmain.go` must come from somewhere. Two routes:

- **Capture (recommended for a POC):** `go list -test` *already generates* the
  testmain into the build cache (it's the `pkg.test` entry's GoFiles path). `godyn-gen`
  already runs `go list`; extend it to `go list -test -deps -json`, read that generated
  file, and embed its contents in the committed graph per test package. Zero
  re-implementation of cmd/go's discovery/template; re-gen when test funcs change
  (same generate-commit contract as the build graph).
- **Replicate (longer-term):** generate `_testmain.go` in `godyn-gen` from the parsed
  `Test*`/`Benchmark*`/`Fuzz*`/`Example*` functions + a vendored template. Removes the
  build-cache dependency but re-implements cmd/go internals (incl. `TestMain`, example
  output checks, fuzz corpus wiring) — defer until the capture POC proves the model.

## `godyn-gen` + builder changes (sketch)

- **gen:** add `-test` to the `go list` invocation; per package emit `testGoFiles`,
  `xTestGoFiles`, the test-variant import set, the external import set, and (capture
  route) the generated `_testmain.go` blob. The test closure's extra deps (testing,
  testdeps, test-only imports) become normal graph nodes.
- **build-godyn-module.nix:** add the five derivations above behind a `doCheck` /
  `tests ? true` knob; expose `passthru.tests.<P>` and an aggregate `passthru.checkAll`
  (the manifest of all `godyn-test-<P>`). Reuse the existing compile-kind branch (pure
  / cgo / asm) for the test-variant compile.

## Edge cases & open questions (to resolve in a POC)

- **Hermeticity:** the nix build sandbox has no network and a fresh cwd/tmp. Hermetic
  tests pass; tests needing network/special env fail — *same limitation as
  buildGoModule `doCheck`*. `testdata/` ships via the package's `builtins.path`, so
  golden-file tests work.
- **Result caching semantics:** a CA `godyn-test-<P>` caches a **passing** result —
  unchanged tests don't re-run (the win), but a flaky test also caches; re-running a
  cached pass needs a cache-bust. Acceptable for deterministic/hermetic tests; document
  it. (`go test` always reruns.)
- **`TestMain`, examples with `// Output:`, fuzz seed corpus:** handled by the
  go-generated testmain on the capture route; must be re-implemented on the replicate
  route.
- **`-race`:** needs the race-instrumented stdlib variant + `compile/link -race` — a
  second stdlib derivation (godynStdlib already parameterises CGO; add a race variant).
- **Runtime flags** (`-run`, `-count`, `-v`, `-test.timeout`): these are *runtime* args
  to the `<P>.test` binary, passed at the `run` derivation — but CA caching means
  `-count=N`/re-run-on-demand interacts with the cache (a `checkPhase`-style
  always-run escape hatch may be needed for `-count`).
- **External test importing test-only exports:** already handled — the external pkg's
  importcfg points at the **test variant** (1), not P's normal archive.

## POC results (built + validated)

Built in `test-poc/` (module `example.com/gtp`: `leaf` with in-package + external
tests, `mid` importing `leaf` with an in-package test) + `test-native.nix` +
`_testmains/{leaf,mid}.go` (the captured testmains) + flake targets
`test-poc-{leaf,mid,all}`. The POC folds the five compiles+link+run into ONE CA
derivation per package; the cross-package boundary is the separate normal `pkgDrvs`.

Confirmed:

- **Tests run + pass in-sandbox.** `nix build .#test-poc-all` → `ok
  example.com/gtp/leaf` / `ok example.com/gtp/mid`. godynStdlib already carries all
  355 std packages incl. `testing` / `testing/internal/testdeps` — no stdlib change
  needed.
- **Failures fail the build** (negative control): a deliberately-broken assertion
  makes `nix build .#test-poc-leaf` fail — real execution, not silent passing.
- **The merkle-delta extends to tests, finer than per-package** (by `.drvPath`
  comparison, which is exact — a stable drvPath means nix won't re-run that test):

  | edit | leaf's test | mid's test |
  |---|---|---|
  | `leaf.go` (code) | re-run | re-run (full cone) |
  | `mid.go` (code) | cached | re-run (only mid) |
  | `leaf_test.go` (in-pkg test) | re-run | **cached** |
  | `leaf_ext_test.go` (external test) | re-run | **cached** |

  Editing a package's **test** re-runs only THAT package's test, never its
  dependents' — vs `go test ./...` / buildGoModule `doCheck` rerunning the whole
  module. The enabling trick: the normal `pkgDrvs` compile sources only non-test
  `.go` (a filtered `builtins.path`), so a `_test.go` edit leaves the normal archive's
  input unchanged and dependents stay cached. (native.nix sources the whole dir; the
  productionized builder should filter for test-awareness.)

## Next step (productionization, not yet done)

1. Automate the capture into a `test-gen` (task #47): `go list -test -deps -json` +
   read the cache-generated `_testmain.go` → `test-graph.json`, replacing the
   hand-written package list in `test-native.nix`.
2. Fold the five steps into separate CA derivations (finer caching: a `_test.go` edit
   needn't relink/recompile what didn't change) when wiring into
   `pkgs/build-support/godyn/build-godyn-module.nix` behind a `doCheck`/`tests` knob.
3. Exercise the remaining edge cases on real fixtures: cgo test, `TestMain`, `-race`
   stdlib variant, a test-only third-party dep (test closure ⊃ build closure).
