// Command godyntb is the godyn-v2 tracer-bullet binary: a 4-package
// leaf -> mid -> top -> main hierarchy with no third-party deps, built three
// ways (native eval-time graph, recursive-nix resolver, buildGoApplication) to
// measure the per-package incremental-rebuild payoff.
package main

import (
	"fmt"

	"example.com/godyntb/internal/top"
)

func main() {
	fmt.Printf("godyntb value = %d\n", top.Value())
}
