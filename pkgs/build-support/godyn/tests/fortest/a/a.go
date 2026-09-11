// Package a is tested by an external test that imports b, which imports a:
// `go test` recompiles b against a's test variant (madder's plugins shape).
package a

func A() string { return "a" }
