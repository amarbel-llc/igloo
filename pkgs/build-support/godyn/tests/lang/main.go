// Fixture: the module declares go 1.21, before Go 1.22's per-iteration loop
// variables, so every closure below shares one i and this prints "333". Compiled
// under go1.22+ language rules it prints "012" — the output shows which language
// version a builder actually applied.
package main

import "fmt"

func main() {
	var fs []func() int
	for i := 0; i < 3; i++ {
		fs = append(fs, func() int { return i })
	}
	for _, f := range fs {
		fmt.Print(f())
	}
	fmt.Println()
}
