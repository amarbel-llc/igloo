// toy-tags: D2 system-under-test for build-tag file selection. variant()
// resolves to base.go (//go:build !godyn_extra) or extra.go
// (//go:build godyn_extra) depending on the build tags. Different program
// output across the two builds proves the resolver threads -tags into go
// list's file selection.
package main

import "fmt"

func main() {
	fmt.Printf("godyn-tags ok: variant = %q\n", variant())
}
