// Package mathx is the leaf first-party package.
package mathx

// Add returns the sum of a and b.
func Add(a, b int) int {
	return addImpl(a, b)
}

func addImpl(a, b int) int {
	return a + b
}
