// Package helper is imported ONLY by leaf's external test — a test-only
// in-graph dependency (it still appears in the build graph via ./...).
package helper

func Expected() int { return 5 }
