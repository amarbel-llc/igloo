package p

import "testing"

func TestWrap(t *testing.T) {
	if got := Wrap(); got != "p wraps q" {
		t.Fatalf("Wrap() = %q", got)
	}
}
