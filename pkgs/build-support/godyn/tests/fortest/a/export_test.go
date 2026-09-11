package a

// Secret exists only in the test variant, so the variant's fingerprint differs
// from the normal package's.
func Secret() string { return "secret" }
