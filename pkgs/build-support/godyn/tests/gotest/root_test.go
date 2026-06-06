package gotest

import "testing"

// TestRoot exercises the dir "." test node: with a string-typed src the
// test-graph relTo must still resolve file paths (same 69c772a regression as
// the build-side filter).
func TestRoot(t *testing.T) {
	if got := Root(); got != "root package" {
		t.Fatalf("Root() = %q, want %q", got, "root package")
	}
}
