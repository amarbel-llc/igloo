// Command selfbin's test drives the module's OWN binary (igloo#88: tests that
// need a real binary, e.g. `spinclass serve`). The binary comes from a second
// buildGodynModule instance placed on the test run's PATH via
// nativeCheckInputs; the compiles are shared (content-addressed).
package main

import "fmt"

func main() {
	fmt.Println("selfbin ok")
}
