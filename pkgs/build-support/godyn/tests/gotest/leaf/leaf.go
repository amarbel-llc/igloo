package leaf

func Add(a, b int) int { return a + b }

// hidden is unexported: only the in-package test can reach it, proving the test
// VARIANT (not the published archive) is what test code compiles against.
func hidden() int { return 40 }
