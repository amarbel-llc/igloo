package leaf

import (
	"os"
	"strings"
	"testing"
)

func TestAdd(t *testing.T) {
	if got := Add(2, 2); got != 4 {
		t.Fatalf("Add(2,2) = %d, want 4", got)
	}
}

func TestHidden(t *testing.T) {
	if got := hidden(); got != 40 {
		t.Fatalf("hidden() = %d, want 40", got)
	}
}

// TestGolden proves testdata/ is present in the run's cwd (go test semantics).
func TestGolden(t *testing.T) {
	b, err := os.ReadFile("testdata/golden.txt")
	if err != nil {
		t.Fatalf("reading golden file: %v", err)
	}
	if got := strings.TrimSpace(string(b)); got != "golden value" {
		t.Fatalf("golden = %q, want %q", got, "golden value")
	}
}
