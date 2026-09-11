package t

import (
	"testing"

	"example.com/q"
)

func TestWithBridgedTestOnlyDep(t *testing.T) {
	if got := T() + "+" + q.Name(); got != "t+q" {
		t.Fatalf("got %q", got)
	}
}
