package main

import (
	"os/exec"
	"strings"
	"testing"
)

// TestOwnBinaryOnPath runs the module's own binary from PATH — the shape of an
// integration test that drives a built CLI. It is NOT built by this test: the
// flake wires a second instance's output into nativeCheckInputs.
func TestOwnBinaryOnPath(t *testing.T) {
	out, err := exec.Command("selfbin").Output()
	if err != nil {
		t.Fatalf("selfbin not runnable; want the module's binary on PATH via nativeCheckInputs: %v", err)
	}
	if !strings.Contains(string(out), "selfbin ok") {
		t.Fatalf("unexpected output %q", out)
	}
}
