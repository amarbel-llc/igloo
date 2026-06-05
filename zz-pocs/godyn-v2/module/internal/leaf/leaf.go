// Package leaf is the bottom of the godyn-v2 tracer-bullet hierarchy: stdlib
// only, the most-depended-upon node. Editing it should rebuild the whole
// leaf -> mid -> top -> main cone under the native eval-time graph.
package leaf

// Base is the seed value the rest of the hierarchy derives from.
func Base() int { return 7 }
