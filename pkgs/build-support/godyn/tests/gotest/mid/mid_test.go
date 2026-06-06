package mid

import (
	"fmt"
	"os"
	"testing"
)

// TestMain proves the captured go-generated testmain wires it exactly as
// `go test` would.
func TestMain(m *testing.M) {
	os.Exit(m.Run())
}

func TestDouble(t *testing.T) {
	if got := Double(21); got != 42 {
		t.Fatalf("Double(21) = %d, want 42", got)
	}
}

// TestBanner proves the test VARIANT compile reproduced the //go:embed.
func TestBanner(t *testing.T) {
	if got := Banner(); got != "godyn test banner" {
		t.Fatalf("Banner() = %q, want %q", got, "godyn test banner")
	}
}

func ExampleDouble() {
	fmt.Println(Double(2))
	// Output: 4
}
