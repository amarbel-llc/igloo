package a_test

import (
	"testing"

	"example.com/fortest/a"
	"example.com/fortest/b"
)

func TestThroughDependent(t *testing.T) {
	if got := a.Secret() + " " + b.B(); got != "secret b+a" {
		t.Fatalf("got %q", got)
	}
}
