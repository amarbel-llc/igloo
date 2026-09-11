// Package bad draws a staticcheck finding (S1002: comparison to a bool constant)
// with no //nolint, so its lint derivation must fail.
package bad

func Truthy(b bool) bool {
	if b == true {
		return true
	}
	return false
}
