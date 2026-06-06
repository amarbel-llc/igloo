// Package greet is module A (example.com/dep), built by godyn and consumed by the
// app module (example.com/app) two ways: as a compiled-archive bridge (approach 1)
// and as source recompiled via go.mod (approach 2).
package greet

// Hello is the cross-module symbol app links against.
func Hello() string { return "hello from dep/greet" }
