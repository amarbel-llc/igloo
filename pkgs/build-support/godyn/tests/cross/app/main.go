// Command app (example.com/app) is module B: a godyn-built binary consuming module
// A (example.com/dep) — built once as bridges (source) and archiveBridges (output).
package main

import (
	"fmt"

	"example.com/dep/greet"
)

func main() { fmt.Println(greet.Hello()) }
