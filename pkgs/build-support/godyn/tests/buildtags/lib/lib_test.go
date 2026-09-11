//go:build test

package lib

import "testing"

func TestHelper(t *testing.T) {
	if got := Helper(); got != "helper:lib" {
		t.Fatalf("Helper() = %q", got)
	}
}
