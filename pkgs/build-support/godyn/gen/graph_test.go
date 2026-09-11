package main

import (
	"reflect"
	"testing"
)

func TestBuildGraphStdImports(t *testing.T) {
	mod := &moduleInfo{Dir: "/m", Main: true}
	pkgs := []goListPkg{
		{ImportPath: "fmt", Standard: true},
		{ImportPath: "unsafe", Standard: true},
		{ImportPath: "example.com/m/a", Dir: "/m/a", Module: mod, GoFiles: []string{"a.go"},
			Imports: []string{"example.com/m/b", "fmt", "unsafe"}},
		{ImportPath: "example.com/m/b", Dir: "/m/b", Module: mod, CgoFiles: []string{"b.go"},
			Imports: []string{"C"}},
	}
	byImport := map[string]genPkg{}
	for _, p := range buildGraph(pkgs).([]genPkg) {
		byImport[p.ImportPath] = p
	}
	for ip, want := range map[string][]string{
		"example.com/m/a": {"fmt"},                   // unsafe needs no vetx; local imports stay in imports
		"example.com/m/b": {"runtime/cgo", "syscall"}, // what cgo's generated sources import
	} {
		if got := byImport[ip].StdImports; !reflect.DeepEqual(got, want) {
			t.Errorf("%s: stdImports = %v, want %v", ip, got, want)
		}
	}
	if got := byImport["example.com/m/a"].Imports; !reflect.DeepEqual(got, []string{"example.com/m/b"}) {
		t.Errorf("imports = %v, want only the in-graph package", got)
	}
}
