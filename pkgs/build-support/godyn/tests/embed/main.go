// Fixture: exercises buildGodynModule's go:embed support (-embedcfg). The binary
// prints the embedded file's content; the flake check asserts on the output.
package main

import (
	_ "embed"
	"fmt"
)

//go:embed message.txt
var message string

func main() {
	fmt.Print(message)
}
