// Package greet builds the user-facing greeting. It sits between main and
// the leaf package mathx, so it is the package whose compiled output we watch
// in the M5 cache-isolation tests (greet must NOT rebuild for a private mathx
// change, but MUST rebuild for an exported mathx change).
package greet

import (
	"fmt"

	"github.com/poc/godyn/internal/mathx"
)

// Greet returns a greeting embedding a computed sum, exercising the first-party
// dependency edge greet -> mathx.
func Greet(name string) string {
	return fmt.Sprintf("hello %s; 2+3=%d", name, sumTwoThree())
}

func sumTwoThree() int {
	return mathx.Add(2, 3)
}
