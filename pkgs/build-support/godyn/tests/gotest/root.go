// Package gotest lives at the MODULE ROOT (dir "." in the graphs) — the
// regression case for the per-package source filter: a string-typed src (what
// flake inputs provide) plus dir "." must not drop every file (69c772a bug).
package gotest

func Root() string { return "root package" }
