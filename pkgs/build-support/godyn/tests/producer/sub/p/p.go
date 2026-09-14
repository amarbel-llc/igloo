// Package p is a flake-input-go_mod producer that itself bridges q.
package p

import "example.com/q"

func Wrap() string { return "p wraps " + q.Name() }
