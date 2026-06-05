// Command godyn-asm exercises the native.nix Plan 9 asm compile path with a
// hand-written amd64 assembly function — no third-party deps, no cgo, no cc.
package main

import (
	"fmt"

	"github.com/poc/godyn-asm/asmpkg"
)

func main() {
	fmt.Printf("godyn-asm: Add(19, 23) = %d\n", asmpkg.Add(19, 23))
}
