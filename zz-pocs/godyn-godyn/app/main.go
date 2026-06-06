// Command app is module B (example.com/app): a godyn-built binary that consumes
// module A (example.com/dep) — the cross-module composition under test.
package main

import (
	"fmt"

	"example.com/dep/greet"
)

func main() {
	fmt.Println(greet.Hello())
}
