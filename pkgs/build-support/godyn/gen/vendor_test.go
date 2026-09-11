package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGoDirective(t *testing.T) {
	for gomod, want := range map[string]string{
		"module a\n\ngo 1.21\n":            "1.21",
		"module a\ngo 1.24.2 // patch\n":    "1.24.2",
		"module a\n\nrequire b v1.0.0\n":    "",
		"module a\ngolang.org/x/y v1\ngo 1.22": "1.22",
	} {
		if got := goDirective([]byte(gomod)); got != want {
			t.Errorf("goDirective(%q) = %q, want %q", gomod, got, want)
		}
	}
}

func TestFillVendoredModules(t *testing.T) {
	root := t.TempDir()
	vendor := filepath.Join(root, "vendor")
	withMod := filepath.Join(vendor, "example.com", "dep")
	noMod := filepath.Join(vendor, "example.com", "old", "pkg")
	for _, d := range []string{filepath.Join(withMod, "greet"), noMod} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(withMod, "go.mod"), []byte("module example.com/dep\n\ngo 1.23.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	pkgs := []goListPkg{
		{ImportPath: "example.com/dep/greet", Dir: filepath.Join(withMod, "greet")},
		{ImportPath: "example.com/old/pkg", Dir: noMod},
		{ImportPath: "fmt", Dir: "/goroot/src/fmt", Standard: true},
	}
	fillVendoredModules(pkgs, root)

	if m := pkgs[0].Module; m == nil || m.Dir != withMod || m.GoVersion != "1.23.0" {
		t.Errorf("vendored package with go.mod: Module = %+v, want Dir %s GoVersion 1.23.0", m, withMod)
	}
	if got := goVersionOf(pkgs[1]); got != "1.16" {
		t.Errorf("vendored package without go.mod: goVersionOf = %q, want 1.16", got)
	}
	if pkgs[2].Module != nil {
		t.Errorf("stdlib package got a module: %+v", pkgs[2].Module)
	}
}
