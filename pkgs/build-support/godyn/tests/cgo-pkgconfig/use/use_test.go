package use

import "testing"

func TestMarked(t *testing.T) {
	if got := Marked(); got != "marked flag-ok" {
		t.Fatalf("Marked() = %q", got)
	}
}
