package ci

import (
	"os/exec"
	"strings"
	"testing"
)

func TestToolOnPath(t *testing.T) {
	out, err := exec.Command("hello").Output()
	if err != nil {
		t.Fatalf("hello not runnable, want it on PATH via nativeCheckInputs: %v", err)
	}
	if !strings.Contains(string(out), "Hello") {
		t.Fatalf("unexpected hello output %q", out)
	}
}
