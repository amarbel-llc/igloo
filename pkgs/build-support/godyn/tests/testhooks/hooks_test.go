package hooks

import (
	"os"
	"path/filepath"
	"testing"
)

// TestWritableHome needs testPreRun's `export HOME=$TMPDIR/home`: the sandbox's
// default HOME is not writable.
func TestWritableHome(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "probe"), []byte("ok"), 0o644); err != nil {
		t.Fatalf("HOME %q not writable, want testPreRun to set it: %v", home, err)
	}
	if os.Getenv("GODYN_PRERUN") != "ran" {
		t.Fatal("testPreRun did not run before the test binary")
	}
}

// TestExcludedByFlags always fails: testFlags' -test.run must skip it.
func TestExcludedByFlags(t *testing.T) {
	t.Fatal("testFlags did not filter this test out")
}
