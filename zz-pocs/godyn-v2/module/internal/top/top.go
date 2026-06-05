// Package top sits just below main.
package top

import "example.com/godyntb/internal/mid"

// Value is the final derived number.
func Value() int { return mid.Doubled() + 1 }
