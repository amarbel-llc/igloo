// Package cfg imports the dagnabit-generated facade (a generated INPUT to the
// tommy step: tommy type-loads this package) and is tommy-generated itself
// (cfg_tommy.go, a generated OUTPUT consumed by cmd/app).
package cfg

import "example.com/gen/pkgs/greeter"

//go:generate tommy generate
type Config struct {
	Name  string `toml:"name"`
	Shout bool   `toml:"shout,omitempty"`
}

func (c Config) Greet() string {
	if c.Shout {
		return greeter.Shout(c.Name, greeter.Opts{Punctuation: "!"})
	}
	return greeter.Hello(c.Name)
}
