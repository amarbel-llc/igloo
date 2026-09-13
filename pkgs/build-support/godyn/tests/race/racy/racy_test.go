package racy

import "testing"

// Passes without -race; under -race the detector fails the test binary.
func TestCount(t *testing.T) {
	if got := Count(); got < 1 {
		t.Fatalf("Count() = %d", got)
	}
}
