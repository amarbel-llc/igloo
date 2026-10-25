package vetxtests_test

import (
	"fmt"
	"testing"

	"example.com/vetxtests"
)

// TestVetBaitExternal passes as a test but carries a printf misuse that vet
// reports; it lives in the external test package (<pkg>_test), which `go vet`
// analyzes as its own unit against the package's test variant. godyn's
// external-test run must surface it (igloo#90).
func TestVetBaitExternal(t *testing.T) {
	if vetxtests.Name() != "vetxtests" {
		t.Fatal("Name")
	}
	_ = fmt.Sprintf("%d", "x")
}
