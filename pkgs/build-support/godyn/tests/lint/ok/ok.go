// Package ok draws the same S1002 finding as package bad, suppressed by a
// golangci-lint v1 linter name, so its lint derivation must pass.
package ok

func Truthy(b bool) bool {
	if b == true { //nolint:gosimple // fixture: suppression under test
		return true
	}
	return false
}
