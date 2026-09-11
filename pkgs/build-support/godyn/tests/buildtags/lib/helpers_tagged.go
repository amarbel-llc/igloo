//go:build test

package lib

// Helper exists only under the `test` tag, like madder's *_test_helpers.go.
func Helper() string { return "helper:" + Name() }
