// External test package of an embed package with in-package tests (igloo#97):
// mid_test is compiled against mid's test VARIANT, whose own compile (and the
// analysis variant sources) must carry mid's //go:embed files.
package mid_test

import (
	"testing"

	"example.com/gotest/mid"
)

func TestBannerExternal(t *testing.T) {
	if got := mid.Banner(); got != "godyn test banner" {
		t.Fatalf("Banner() = %q, want %q", got, "godyn test banner")
	}
}
