package vetxtests

import "testing"

// TestNameInPackage is clean: the in-package variant must stay green so the
// finding below is attributable to the external test package alone.
func TestNameInPackage(t *testing.T) {
	if Name() != "vetxtests" {
		t.Fatal("Name")
	}
}
