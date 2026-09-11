// Package b depends on a; a's external test imports it.
package b

import "example.com/fortest/a"

func B() string { return "b+" + a.A() }
