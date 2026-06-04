// Package mathx is the leaf first-party package — the one we edit in M5.
package mathx

// Add returns the sum of a and b. Its EXPORTED signature is the cache
// boundary: changing it (S3) must cascade to greet's compiled output.
func Add(a, b int) int {
	return addImpl(a, b)
}

// addImpl is private. Changing ONLY its body (S2) must not change greet's
// compiled output — that is the per-package isolation the POC is proving.
func addImpl(a, b int) int {
	return a + b
}
