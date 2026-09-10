// Fixture: //go:embed shapes beyond a literal file (igloo#68) — a mid-path glob
// (templates/*.md.tmpl; ignore.txt must stay out) and a directory pattern (static:
// recursive, minus the dot-file). Prints what was embedded; the flake check asserts
// on the output. Before igloo#68 the glob embedded nothing and this panicked.
package main

import (
	"embed"
	"fmt"
	"io/fs"
)

//go:embed templates/*.md.tmpl
var templates embed.FS

//go:embed static
var static embed.FS

func main() {
	names, err := fs.Glob(templates, "templates/*")
	if err != nil || len(names) == 0 {
		panic(fmt.Sprintf("templates: %v %v", names, err))
	}
	for _, n := range names {
		b, err := fs.ReadFile(templates, n)
		if err != nil {
			panic(err)
		}
		fmt.Print(string(b))
	}
	err = fs.WalkDir(static, "static", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			fmt.Println(p)
		}
		return err
	})
	if err != nil {
		panic(err)
	}
}
