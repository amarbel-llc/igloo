// Command manifest is built from go.nix alone (FDR 0008): its tree has no go.mod.
// It links a third-party module (go-cmp, which declares go 1.13) and a fleet module
// (example.com/dep) resolved through a flake input.
package main

import (
	"fmt"

	"example.com/dep/greet"
	"github.com/google/go-cmp/cmp"
)

func main() {
	fmt.Println(greet.Hello(), cmp.Equal([]int{1, 2}, []int{1, 2}))
}
