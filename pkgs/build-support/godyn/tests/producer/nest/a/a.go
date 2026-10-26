// Package a is the parent of two NESTED modules in one published tree: a/sub
// has its own go.mod under a's directory (purse-first's go-mcp and
// go-mcp/command/huh shape, spinclass#157).
package a

func Name() string { return "a" }
