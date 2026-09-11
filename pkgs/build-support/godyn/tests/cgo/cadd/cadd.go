// Package cadd is a cgo package: a Go wrapper over C code. Its importers can only
// be type-checked through its type data, so it exercises the analysis lanes over
// cgo packages.
package cadd

/*
static int add(int a, int b) { return a + b; }
*/
import "C"

// Add returns a+b, computed in C.
func Add(a, b int) int {
	return int(C.add(C.int(a), C.int(b)))
}
