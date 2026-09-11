package p

import (
	"os"
	"strings"
	"testing"
)

func TestReadsModuleFile(t *testing.T) {
	b, err := os.ReadFile("../../docs/vec.txt")
	if err != nil {
		t.Fatalf("reading a module file outside the package: %v", err)
	}
	if strings.TrimSpace(string(b)) != "vector-ok" {
		t.Fatalf("unexpected content %q", b)
	}
}
