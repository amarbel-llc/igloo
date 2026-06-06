package leaf

import "testing"

// In-package test: can see unexported identifiers.
func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatalf("Add(1,2) = %d, want 3", Add(1, 2))
	}
}
