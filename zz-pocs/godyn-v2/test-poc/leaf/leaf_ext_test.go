package leaf_test

import (
	"testing"

	"example.com/gtp/leaf"
)

// External test: package leaf_test, imports leaf as a consumer would.
func TestAddExternal(t *testing.T) {
	if leaf.Add(2, 2) != 4 {
		t.Fatalf("leaf.Add(2,2) = %d, want 4", leaf.Add(2, 2))
	}
}
