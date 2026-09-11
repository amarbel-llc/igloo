package user

import (
	"os"
	"testing"

	"example.com/tags/lib"
)

// Untagged test file that calls a tagged helper in ANOTHER package: it only
// compiles when lib itself was built with -tags test.
func TestUsesTaggedHelper(t *testing.T) {
	if got := lib.Helper(); got != "helper:lib" {
		t.Fatalf("lib.Helper() = %q", got)
	}
	if Use() != "uses lib" {
		t.Fatalf("Use() = %q", Use())
	}
}

func TestEnv(t *testing.T) {
	if got := os.Getenv("GODYN_TEST_ENV"); got != "set" {
		t.Fatalf("GODYN_TEST_ENV = %q, want testEnv to set it", got)
	}
}
