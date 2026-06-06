// External test package: compiled as leaf_test against the test VARIANT's
// archive. Imports helper — a package nothing in the build graph imports —
// exercising test-only in-graph deps.
package leaf_test

import (
	"testing"

	"example.com/gotest/helper"
	"example.com/gotest/leaf"
)

func TestAddExternal(t *testing.T) {
	if got := leaf.Add(2, 3); got != helper.Expected() {
		t.Fatalf("Add(2,3) = %d, want %d", got, helper.Expected())
	}
}
