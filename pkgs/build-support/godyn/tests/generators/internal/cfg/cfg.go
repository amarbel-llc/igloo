// Package cfg imports the generated facade (pkgs/hello) and uses a constant the
// second generator writes (cfg_gen.go).
package cfg

import "example.com/genstub/pkgs/hello"

func Greet() string { return hello.Hello() + cfgSuffix }
