// Command godyn-gen is the dev-time generator for the godyn native eval-time
// graph. It runs `go list -deps -json <packages>` over a Go module and emits a
// committed graph.json that buildGodynModule turns into one derivation per
// package. Re-run it only when the import structure or file set changes — a
// content-only edit does not need a regen (same contract as gomod2nix.toml).
//
// With -tests it runs `go list -test -deps -json` instead and emits a TEST
// graph: one node per tested package carrying the test file lists, the test
// variant's imports (a superset including test-only deps), and the captured
// go-generated _testmain.go source (go list -test materialises it in the build
// cache — the "capture route", so TestMain/Examples/fuzz wiring is exactly what
// `go test` would produce). buildGodynModule consumes it via testGraphFile.
//
// With -gomod it resolves the module graph against an alternate go.mod — for a
// goFlakeInputs consumer, buildGoApplication's passthru.mergedGoMod, whose
// replaces point bridged modules at their flake-version go-pkgs — so the graph
// records the files the build will actually compile (igloo#67).
//
// Usage: godyn-gen [-tests] [-gomod <go.mod>] <module-dir> <out-graph.json> [packages...]
// packages defaults to ./... ; pass e.g. ./internal/delta/... to emit only that
// subtree's transitive closure (go list -deps follows imports across the scope).
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// goListPkg is the subset of `go list -json` fields we consume. ForTest and the
// Test*/XTest* file lists only populate under -test.
type goListPkg struct {
	ImportPath    string
	Dir           string
	Name          string
	Standard      bool
	ForTest       string
	GoFiles       []string
	TestGoFiles   []string
	XTestGoFiles  []string
	CgoFiles      []string
	CFiles        []string
	HFiles        []string
	SFiles        []string
	EmbedFiles    []string
	EmbedPatterns []string
	CXXFiles      []string
	FFiles        []string
	SwigFiles     []string
	SwigCXXFile   []string `json:"SwigCXXFiles"`
	CgoCFLAGS     []string // from #cgo directives; cmd/go adds them when invoking cgo
	CgoCPPFLAGS   []string
	CgoLDFLAGS    []string
	CgoPkgConfig  []string // #cgo pkg-config names; cmd/go resolves them at build time
	Imports       []string
	Module        *moduleInfo
}

type moduleInfo struct {
	Dir       string
	Main      bool
	GoVersion string // the module's go directive; empty when it has none
}

// fillVendoredModules supplies the module that go list leaves out in vendor mode:
// with a vendor tree that has no modules.txt (gomod2nix's, used under
// GO_NO_VENDOR_CHECKS — e.g. when the graph is derived at eval time inside a
// buildGoApplication sandbox, FDR 0008), vendored packages carry no Module, so
// their module root and go directive are recovered from the nearest go.mod above
// the package inside vendor/.
func fillVendoredModules(pkgs []goListPkg, moduleDir string) {
	vendorRoot, err := filepath.Abs(filepath.Join(moduleDir, "vendor"))
	if err != nil {
		return
	}
	for i := range pkgs {
		p := &pkgs[i]
		if p.Standard || p.Module != nil {
			continue
		}
		if rel, err := filepath.Rel(vendorRoot, p.Dir); err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
			continue
		}
		p.Module = vendoredModule(vendorRoot, p.Dir)
	}
}

// vendoredModule finds the module containing a vendored package dir: the nearest
// directory at or above it (below vendorRoot) holding a go.mod. A module without
// one gets no go version, so goVersionOf applies cmd/go's 1.16 default.
func vendoredModule(vendorRoot, dir string) *moduleInfo {
	for d := dir; d != vendorRoot && strings.HasPrefix(d, vendorRoot+string(filepath.Separator)); d = filepath.Dir(d) {
		if data, err := os.ReadFile(filepath.Join(d, "go.mod")); err == nil {
			return &moduleInfo{Dir: d, GoVersion: goDirective(data)}
		}
	}
	return &moduleInfo{Dir: dir}
}

// goDirective is the version on a go.mod's `go` line, or "" if it has none.
func goDirective(gomod []byte) string {
	for _, line := range strings.Split(string(gomod), "\n") {
		if f := strings.Fields(line); len(f) >= 2 && f[0] == "go" {
			return f[1]
		}
	}
	return ""
}

// goVersionOf is the language version `go build` compiles p's module at: its go
// directive, or 1.16 — cmd/go's default for a module without one.
func goVersionOf(p goListPkg) string {
	switch {
	case p.Module == nil:
		return ""
	case p.Module.GoVersion == "":
		return "1.16"
	default:
		return p.Module.GoVersion
	}
}

// genPkg is one node in the emitted build graph: enough for buildGodynModule to
// construct a per-package compile derivation wired to its deps. Compile-kind
// (pure/cgo/asm) is derived from the file lists, orthogonally to source-kind
// (local/vendor/bridge).
type genPkg struct {
	ImportPath        string              `json:"importPath"`
	Dir               string              `json:"dir"`                         // for local pkgs: module-root-relative ("internal/leaf", "."); third-party: unused
	Name              string              `json:"name"`                        // package name; "main" links a binary
	IsMain            bool                `json:"isMain"`                      //
	Local             bool                `json:"local"`                       // in the main module (src=module/dir) vs third-party (src=vendorEnv/importPath)
	GoFiles           []string            `json:"goFiles"`                     // non-test .go files (basenames)
	CgoFiles          []string            `json:"cgoFiles"`                    // .go files with `import "C"` (non-empty => cgo path)
	CFiles            []string            `json:"cFiles"`                      // C source compiled with cc
	HFiles            []string            `json:"hFiles"`                      // C headers (kept so includes resolve)
	SFiles            []string            `json:"sFiles"`                      // .s = Plan 9 asm (go tool asm); .S/.sx = gcc asm (cc)
	EmbedFiles        []string            `json:"embedFiles"`                  // files matched by //go:embed (need -embedcfg at compile)
	EmbedPatterns     []string            `json:"embedPatterns"`               // the //go:embed patterns themselves
	EmbedPatternFiles map[string][]string `json:"embedPatternFiles,omitempty"` // pattern -> the embedFiles it matched (-embedcfg Patterns)
	Imports           []string            `json:"imports"`                     // direct, in-graph (non-stdlib) imports
	GoVersion         string              `json:"goVersion,omitempty"`         // the package's module's language version (-lang)
	StdImports        []string            `json:"stdImports"`                  // direct stdlib imports (always present: absent = an older gen)
	CgoCFlags         []string            `json:"cgoCFLAGS,omitempty"`         // #cgo CPPFLAGS + CFLAGS
	CgoLDFlags        []string            `json:"cgoLDFLAGS,omitempty"`        // #cgo LDFLAGS
	CgoPkgConfig      []string            `json:"cgoPkgConfig,omitempty"`      // #cgo pkg-config names
}

// genTestPkg is one node in the emitted TEST graph: one per tested package.
type genTestPkg struct {
	ImportPath   string   `json:"importPath"`
	Dir          string   `json:"dir"`          // module-root-relative
	GoFiles      []string `json:"goFiles"`      // the package's non-test sources (the variant compiles these too)
	TestGoFiles  []string `json:"testGoFiles"`  // in-package _test.go files
	XTestGoFiles []string `json:"xTestGoFiles"` // external (package <name>_test) _test.go files
	Imports      []string `json:"imports"`      // the VARIANT's in-graph imports — a superset incl. test-only deps
	XTestImports []string `json:"xTestImports"` // the external package's in-graph imports, minus the variant itself
	TestMain     string   `json:"testmain"`     // the captured go-generated _testmain.go source
	GoVersion    string   `json:"goVersion,omitempty"` // the module's language version (-lang)
}

const usage = "usage: godyn-gen [-tests] [-gomod <go.mod>] <module-dir> <out-graph.json> [packages...]"

func main() {
	testsMode := flag.Bool("tests", false, "emit the TEST graph (go list -test) instead of the build graph")
	gomod := flag.String("gomod", "", "resolve against this go.mod instead of <module-dir>/go.mod (e.g. passthru.mergedGoMod); the tracked go.mod is not touched")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, usage)
		flag.PrintDefaults()
	}
	flag.Parse()
	args := flag.Args()
	if len(args) < 2 {
		fatalf(usage)
	}
	moduleDir, outPath := args[0], args[1]
	patterns := args[2:]
	if len(patterns) == 0 {
		patterns = []string{"./..."}
	}

	listArgs := []string{"list"}
	if *testsMode {
		listArgs = append(listArgs, "-test")
	}
	cleanup := func() {}
	if *gomod != "" {
		dir, err := stageModfile(*gomod, moduleDir)
		if err != nil {
			fatalf("staging -gomod: %v", err)
		}
		cleanup = func() { os.RemoveAll(dir) }
		// -mod=mod: bridged producers can require versions the consumer's go.sum
		// never recorded; let go add them to the throwaway staged go.sum.
		listArgs = append(listArgs, "-modfile="+filepath.Join(dir, "go.mod"), "-mod=mod")
	}
	listArgs = append(listArgs, "-deps", "-json")
	listArgs = append(listArgs, patterns...)
	cmd := exec.Command("go", listArgs...)
	cmd.Dir = moduleDir
	// GOFLAGS / CGO_ENABLED / CC come from the caller: CGO_ENABLED=1 + CC for a
	// module with cgo (so CgoFiles populate), -mod=vendor when third-party deps
	// are materialised into vendor/. GOOS/GOARCH pass through too, so every
	// platform's graph can be generated from one host. Pure-Go targets leave CGO
	// at its default.
	cmd.Env = os.Environ()
	data, err := cmd.Output()
	cleanup()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			fatalf("go list: %v\n%s", err, ee.Stderr)
		}
		fatalf("go list: %v", err)
	}

	var pkgs []goListPkg
	dec := json.NewDecoder(bytes.NewReader(data))
	for dec.More() {
		var p goListPkg
		if err := dec.Decode(&p); err != nil {
			fatalf("decode go list json: %v", err)
		}
		pkgs = append(pkgs, p)
	}
	fillVendoredModules(pkgs, moduleDir)

	if *testsMode {
		writeJSON(outPath, testGraph(pkgs))
		return
	}
	writeJSON(outPath, buildGraph(pkgs))
}

// stageModfile copies an alternate go.mod, plus the module's go.sum (which
// -modfile reads from beside the alternate file), into a new temp dir so go list
// can resolve against it without touching the tracked go.mod.
func stageModfile(gomod, moduleDir string) (string, error) {
	dir, err := os.MkdirTemp("", "godyn-gen-modfile-")
	if err != nil {
		return "", err
	}
	err = copyFile(gomod, filepath.Join(dir, "go.mod"))
	if err == nil {
		err = copyFile(filepath.Join(moduleDir, "go.sum"), filepath.Join(dir, "go.sum"))
		if os.IsNotExist(err) {
			err = nil
		}
	}
	if err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	return dir, nil
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}

func buildGraph(pkgs []goListPkg) any {
	// The set of non-stdlib import paths — an import is an in-graph edge iff it
	// is in this set (stdlib comes from the shared stdlib derivation).
	local, std := map[string]bool{}, map[string]bool{}
	for _, p := range pkgs {
		if p.Standard {
			std[p.ImportPath] = true
		} else {
			local[p.ImportPath] = true
		}
	}

	var graph []genPkg
	for _, p := range pkgs {
		if p.Standard {
			continue
		}
		dir := "."
		if p.Module != nil {
			if rel, err := filepath.Rel(p.Module.Dir, p.Dir); err == nil {
				dir = rel
			}
		}
		if n := len(p.CXXFiles) + len(p.FFiles) + len(p.SwigFiles) + len(p.SwigCXXFile); n > 0 {
			fatalf("package %s has unsupported sources (C++/Fortran/SWIG)", p.ImportPath)
		}
		var imps []string
		stdSet := map[string]bool{}
		for _, i := range p.Imports {
			switch {
			case local[i]:
				imps = append(imps, i)
			case std[i] && i != "unsafe":
				stdSet[i] = true
			}
		}
		if len(p.CgoFiles) > 0 {
			// cgo's generated sources import these as well
			stdSet["runtime/cgo"], stdSet["syscall"] = true, true
		}
		stdImps := make([]string, 0, len(stdSet))
		for i := range stdSet {
			stdImps = append(stdImps, i)
		}
		sort.Strings(imps)
		sort.Strings(stdImps)
		graph = append(graph, genPkg{
			ImportPath:        p.ImportPath,
			Dir:               dir,
			Name:              p.Name,
			IsMain:            p.Name == "main",
			Local:             p.Module != nil && p.Module.Main,
			GoFiles:           p.GoFiles,
			CgoFiles:          p.CgoFiles,
			CFiles:            p.CFiles,
			HFiles:            p.HFiles,
			SFiles:            p.SFiles,
			EmbedFiles:        p.EmbedFiles,
			EmbedPatterns:     p.EmbedPatterns,
			EmbedPatternFiles: embedPatternFiles(p.ImportPath, p.EmbedPatterns, p.EmbedFiles),
			Imports:           imps,
			GoVersion:         goVersionOf(p),
			StdImports:        stdImps,
			CgoCFlags:         append(append([]string(nil), p.CgoCPPFLAGS...), p.CgoCFLAGS...),
			CgoLDFlags:        p.CgoLDFLAGS,
			CgoPkgConfig:      p.CgoPkgConfig,
		})
	}
	sort.Slice(graph, func(i, j int) bool { return graph[i].ImportPath < graph[j].ImportPath })
	return graph
}

// embedPatternFiles attributes go list's resolved EmbedFiles to the //go:embed
// patterns that matched them, so buildGodynModule can write -embedcfg without
// re-implementing cmd/go's glob rules in Nix (igloo#68).
func embedPatternFiles(importPath string, patterns, files []string) map[string][]string {
	if len(patterns) == 0 {
		return nil
	}
	out := map[string][]string{}
	for _, raw := range patterns {
		pat, all := strings.CutPrefix(raw, "all:")
		var matched []string
		for _, f := range files {
			if embedMatch(pat, f, all) {
				matched = append(matched, f)
			}
		}
		if len(matched) == 0 {
			fatalf("package %s: //go:embed %s matches none of go list's EmbedFiles", importPath, raw)
		}
		sort.Strings(matched)
		out[raw] = matched
	}
	return out
}

// embedMatch reports whether cmd/go embeds file for pat: a direct glob match
// (dot/underscore names included), or a match on an ancestor directory, whose
// subtree is embedded except names beginning with '.' or '_' unless all: is set.
func embedMatch(pat, file string, all bool) bool {
	if ok, _ := path.Match(pat, file); ok {
		return true
	}
	for dir := path.Dir(file); dir != "."; dir = path.Dir(dir) {
		if ok, _ := path.Match(pat, dir); !ok {
			continue
		}
		if all {
			return true
		}
		for _, elem := range strings.Split(strings.TrimPrefix(file, dir+"/"), "/") {
			if strings.HasPrefix(elem, ".") || strings.HasPrefix(elem, "_") {
				return false
			}
		}
		return true
	}
	return false
}

// testGraph groups the synthesized packages `go list -test` adds for each tested
// package P — the recompiled variant "P [P.test]", the external "P_test [P.test]",
// and the generated testmain "P.test" — back onto P, and captures the generated
// _testmain.go from the build cache.
func testGraph(pkgs []goListPkg) any {
	// Strip the " [P.test]" suffix marking recompiled variants.
	clean := func(ip string) string {
		if i := strings.Index(ip, " ["); i >= 0 {
			return ip[:i]
		}
		return ip
	}

	// Non-stdlib import paths (cleaned) — in-graph edge candidates. Test-only
	// third-party deps land here too; buildGodynModule reports them as
	// unsupported when actually referenced.
	nonStd := map[string]bool{}
	for _, p := range pkgs {
		if !p.Standard {
			nonStd[clean(p.ImportPath)] = true
		}
	}

	type group struct {
		base, variant, xtest, testmain *goListPkg
	}
	groups := map[string]*group{}
	grp := func(ip string) *group {
		if groups[ip] == nil {
			groups[ip] = &group{}
		}
		return groups[ip]
	}
	for i := range pkgs {
		p := &pkgs[i]
		if p.Standard {
			continue
		}
		ip := clean(p.ImportPath)
		switch {
		case p.ForTest == "" && strings.HasSuffix(ip, ".test") && p.Name == "main":
			grp(strings.TrimSuffix(ip, ".test")).testmain = p
		case p.ForTest == "":
			grp(ip).base = p
		case ip == p.ForTest:
			grp(p.ForTest).variant = p
		case ip == p.ForTest+"_test":
			grp(p.ForTest).xtest = p
		}
	}

	filterImports := func(imps []string, self string) []string {
		seen := map[string]bool{}
		var out []string
		for _, i := range imps {
			c := clean(i)
			if c == self || seen[c] || !nonStd[c] || strings.HasSuffix(c, ".test") {
				continue
			}
			seen[c] = true
			out = append(out, c)
		}
		sort.Strings(out)
		return out
	}

	var graph []genTestPkg
	for ip, g := range groups {
		if g.base == nil || g.testmain == nil {
			continue // no tests for this package
		}
		if g.base.Module == nil || !g.base.Module.Main {
			continue // only the main module's packages carry tests in the graph
		}
		// The variant only exists when there are in-package tests; with external
		// tests only, the testmain links against the plain package — compiling
		// the variant from base files is equivalent.
		v := g.variant
		if v == nil {
			v = g.base
		}
		if len(g.testmain.GoFiles) != 1 {
			fatalf("package %s: expected exactly one generated testmain source, got %v", ip, g.testmain.GoFiles)
		}
		// The generated source lives in the go build cache: go list -test reports
		// it as an ABSOLUTE GoFiles entry (a cache object), with Dir still the
		// package source dir. Join only relative entries.
		tmPath := g.testmain.GoFiles[0]
		if !filepath.IsAbs(tmPath) {
			tmPath = filepath.Join(g.testmain.Dir, tmPath)
		}
		tm, err := os.ReadFile(tmPath)
		if err != nil {
			fatalf("package %s: reading generated testmain from the go build cache: %v", ip, err)
		}
		dir := "."
		if rel, err := filepath.Rel(g.base.Module.Dir, g.base.Dir); err == nil {
			dir = rel
		}
		var xImports []string
		if g.xtest != nil {
			xImports = filterImports(g.xtest.Imports, ip)
		}
		graph = append(graph, genTestPkg{
			ImportPath:   ip,
			Dir:          dir,
			GoFiles:      g.base.GoFiles,
			TestGoFiles:  g.base.TestGoFiles,
			XTestGoFiles: g.base.XTestGoFiles,
			Imports:      filterImports(v.Imports, ip),
			XTestImports: xImports,
			TestMain:     string(tm),
			GoVersion:    goVersionOf(*g.base),
		})
	}
	sort.Slice(graph, func(i, j int) bool { return graph[i].ImportPath < graph[j].ImportPath })
	return graph
}

func writeJSON(outPath string, graph any) {
	b, err := json.MarshalIndent(graph, "", "  ")
	if err != nil {
		fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(outPath, append(b, '\n'), 0o644); err != nil {
		fatalf("write %s: %v", outPath, err)
	}
	n := 0
	if v, ok := graph.([]genPkg); ok {
		n = len(v)
	} else if v, ok := graph.([]genTestPkg); ok {
		n = len(v)
	}
	fmt.Fprintf(os.Stderr, "[godyn-gen] wrote %d packages to %s\n", n, outPath)
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "godyn-gen: "+format+"\n", a...)
	os.Exit(1)
}
