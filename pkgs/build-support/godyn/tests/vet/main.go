// Fixture: a printf misuse through a wrapper in another package. vet can only
// flag it from the logf package's facts, so the finding proves the per-package
// vet lane threads facts between packages.
package main

import "example.com/vet/logf"

func main() {
	logf.Logf("%d\n", "not a number")
}
