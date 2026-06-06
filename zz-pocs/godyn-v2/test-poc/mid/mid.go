package mid

import "example.com/gtp/leaf"

// Double returns 2*x, built on leaf.Add — so mid's test cone includes leaf.
func Double(x int) int { return leaf.Add(x, x) }
