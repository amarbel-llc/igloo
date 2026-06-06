// Package mid depends on leaf and carries a //go:embed — the test VARIANT
// compile must reproduce the embedcfg.
package mid

import (
	_ "embed"

	"example.com/gotest/leaf"
)

//go:embed banner.txt
var banner string

func Double(x int) int { return leaf.Add(x, x) }

func Banner() string { return banner }
