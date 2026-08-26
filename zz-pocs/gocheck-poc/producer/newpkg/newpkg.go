// Package newpkg exists ONLY in this producer source, not at the version
// example.com/producer v1.0.0 that the consumer's go.mod requires (that
// version is fictional and unreachable via any proxy). If a tool resolves
// this symbol, it did so through the goFlakeInputs bridge — the mesa-shaped
// case (a package present only in a bridged producer's newer rev).
package newpkg

// Value returns a constant the consumer prints.
func Value() int { return 1 }
