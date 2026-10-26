// Package sub is a module whose path is nested under module a's path and
// whose directory is nested under a's directory.
package sub

import "example.com/n/a"

func Name() string { return a.Name() + " sub" }
