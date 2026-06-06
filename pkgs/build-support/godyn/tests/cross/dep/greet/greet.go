// Package greet is module A (example.com/dep), consumed by the app module two ways:
// as a compiled-archive bridge (archiveBridges) and as source (bridges).
package greet

func Hello() string { return "hello from dep/greet" }
