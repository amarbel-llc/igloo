package vettests

import (
	"fmt"
	"testing"
)

// TestVetBait passes as a test (Sprintf with a mismatched verb only yields
// "%!d(string=x)") but carries a printf misuse that vet reports — the finding
// godyn's test-variant analysis must surface (igloo#90).
func TestVetBait(t *testing.T) {
	if Name() != "vettests" {
		t.Fatal("Name")
	}
	_ = fmt.Sprintf("%d", "x")
}
