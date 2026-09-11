// Package p's test reads a module file outside the package via a relative path
// (cutting-garden's internal/trellis reading ../../docs/rfcs/... shape).
package p

func P() string { return "p" }
