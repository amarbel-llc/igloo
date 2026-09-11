// Package use is pure Go over the cgo package zv: its test binary links
// externally (madder's plugins/zstd over DataDog/zstd shape).
package use

import "example.com/cgopc/zv"

func Marked() string { return "marked " + zv.Mark() }
