package mid

import "testing"

func TestDouble(t *testing.T) {
	if Double(3) != 6 {
		t.Fatalf("Double(3) = %d, want 6", Double(3))
	}
}
