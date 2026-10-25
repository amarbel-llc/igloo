package gotest

import (
	"fmt"
	"testing"
)

// TestRoot exercises the dir "." test node: with a string-typed src the
// test-graph relTo must still resolve file paths (same 69c772a regression as
// the build-side filter).
func TestRoot(t *testing.T) {
	if got := Root(); got != "root package" {
		t.Fatalf("Root() = %q, want %q", got, "root package")
	}
}

// TestVetBait passes as a test (Sprintf with a mismatched verb only yields
// "%!d(string=x)") but carries a printf misuse that vet reports — the finding
// godyn's test-variant analysis lane must surface (igloo#90). The package's
// non-test vet stays clean, which godyn-vet-clean-test asserts.
func TestVetBait(t *testing.T) {
	_ = fmt.Sprintf("%d", "x")
}
