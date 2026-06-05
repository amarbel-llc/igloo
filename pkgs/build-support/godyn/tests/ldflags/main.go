// Fixture: exercises buildGodynModule's ldflags support (-X main.version=...).
// `version` is overwritten by the linker; the flake check asserts on the output.
package main

import "fmt"

var version = "unset"

func main() {
	fmt.Printf("version=%s\n", version)
}
