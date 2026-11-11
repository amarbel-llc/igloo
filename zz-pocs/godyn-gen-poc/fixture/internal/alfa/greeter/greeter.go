// Package greeter is an internal package whose facade dagnabit generates into
// pkgs/greeter (dagnabit output; never committed).
package greeter

//go:generate dagnabit export

type Opts struct{ Punctuation string }

// Hello greets name.
func Hello(name string) string { return "hello, " + name }

func Shout(name string, o Opts) string { return Hello(name) + o.Punctuation }
