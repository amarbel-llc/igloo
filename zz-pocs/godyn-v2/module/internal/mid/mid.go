// Package mid sits one level above leaf.
package mid

import "example.com/godyntb/internal/leaf"

// Doubled doubles the leaf seed.
func Doubled() int { return leaf.Base() * 2 }
