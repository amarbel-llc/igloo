// Package logf is a printf wrapper: vet's printf analyzer records that as a fact
// on this package, which the importing package's analysis needs to flag misuse.
package logf

import "fmt"

func Logf(format string, args ...any) {
	fmt.Printf(format, args...)
}
