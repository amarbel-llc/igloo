// Single-package module for M2: imports only the standard library, so the
// resolver produces exactly one compile derivation + one link derivation
// (no first-party importcfg cross-wiring yet).
package main

import "fmt"

func main() {
	fmt.Println("godyn single-package M2 ok")
}
