// Command godyn-gen is the dev-time generator for the godyn-v2 native eval-time
// graph. It runs `go list -deps -json ./...` over a Go module and emits a
// committed graph.json that native.nix turns into one derivation per package.
// Re-run it (just gen) only when the import structure or file set changes — a
// content-only edit does not need a regen (same contract as gomod2nix.toml).
//
// Usage: godyn-gen <module-dir> <out-graph.json> [packages...]
// packages defaults to ./... ; pass e.g. ./internal/delta/... to emit only that
// subtree's transitive closure (go list -deps follows imports across the scope).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
)

// goListPkg is the subset of `go list -json` fields we consume.
type goListPkg struct {
	ImportPath  string
	Dir         string
	Name        string
	Standard    bool
	GoFiles     []string
	CgoFiles    []string
	CFiles      []string
	HFiles      []string
	SFiles      []string
	CXXFiles    []string
	FFiles      []string
	SwigFiles   []string
	SwigCXXFile []string `json:"SwigCXXFiles"`
	Imports     []string
	Module      *struct {
		Dir  string
		Main bool
	}
}

// genPkg is one node in the emitted graph: enough for native.nix to construct a
// per-package compile derivation wired to its deps. Compile-kind (pure/cgo/asm)
// is derived from the file lists, orthogonally to source-kind (local/vendor).
type genPkg struct {
	ImportPath string   `json:"importPath"`
	Dir        string   `json:"dir"`      // for local pkgs: module-root-relative ("internal/leaf", "."); third-party: unused
	Name       string   `json:"name"`     // package name; "main" links a binary
	IsMain     bool     `json:"isMain"`   //
	Local      bool     `json:"local"`    // in the main module (src=module/dir) vs third-party (src=vendorEnv/importPath)
	GoFiles    []string `json:"goFiles"`  // non-test .go files (basenames)
	CgoFiles   []string `json:"cgoFiles"` // .go files with `import "C"` (non-empty => cgo path)
	CFiles     []string `json:"cFiles"`   // C source compiled with cc
	HFiles     []string `json:"hFiles"`   // C headers (kept so includes resolve)
	SFiles     []string `json:"sFiles"`   // .s = Plan 9 asm (go tool asm); .S/.sx = gcc asm (cc)
	Imports    []string `json:"imports"`  // direct, in-graph (non-stdlib) imports
}

func main() {
	if len(os.Args) < 3 {
		fatalf("usage: godyn-gen <module-dir> <out-graph.json> [packages...]")
	}
	moduleDir, outPath := os.Args[1], os.Args[2]
	patterns := os.Args[3:]
	if len(patterns) == 0 {
		patterns = []string{"./..."}
	}

	cmd := exec.Command("go", append([]string{"list", "-deps", "-json"}, patterns...)...)
	cmd.Dir = moduleDir
	// GOFLAGS / CGO_ENABLED / CC come from the caller: CGO_ENABLED=1 + CC for a
	// module with cgo (so CgoFiles populate), -mod=vendor when third-party deps
	// are materialised into vendor/. Pure-Go targets leave CGO at its default.
	cmd.Env = os.Environ()
	data, err := cmd.Output()
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

	// The set of non-stdlib import paths — an import is an in-graph edge iff it
	// is in this set (stdlib comes from the shared stdlib derivation).
	local := map[string]bool{}
	for _, p := range pkgs {
		if !p.Standard {
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
		for _, i := range p.Imports {
			if local[i] {
				imps = append(imps, i)
			}
		}
		sort.Strings(imps)
		graph = append(graph, genPkg{
			ImportPath: p.ImportPath,
			Dir:        dir,
			Name:       p.Name,
			IsMain:     p.Name == "main",
			Local:      p.Module != nil && p.Module.Main,
			GoFiles:    p.GoFiles,
			CgoFiles:   p.CgoFiles,
			CFiles:     p.CFiles,
			HFiles:     p.HFiles,
			SFiles:     p.SFiles,
			Imports:    imps,
		})
	}
	sort.Slice(graph, func(i, j int) bool { return graph[i].ImportPath < graph[j].ImportPath })

	b, err := json.MarshalIndent(graph, "", "  ")
	if err != nil {
		fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(outPath, append(b, '\n'), 0o644); err != nil {
		fatalf("write %s: %v", outPath, err)
	}
	fmt.Fprintf(os.Stderr, "[godyn-gen] wrote %d packages to %s\n", len(graph), outPath)
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "godyn-gen: "+format+"\n", a...)
	os.Exit(1)
}
