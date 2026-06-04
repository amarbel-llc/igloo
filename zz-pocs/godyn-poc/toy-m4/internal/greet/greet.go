// Package greet builds the greeting. In the M4 variant it imports a
// third-party module (github.com/google/uuid) so the build exercises the
// FOD -> GOMODCACHE -> per-package third-party compile path. The uuid is
// derived deterministically (NewSHA1) so the binary's output is stable and
// proves uuid was fetched, compiled, and linked.
package greet

import (
	"fmt"

	"github.com/google/uuid"
	"github.com/poc/godyn/internal/mathx"
)

func Greet(name string) string {
	id := uuid.NewSHA1(uuid.NameSpaceDNS, []byte(name)).String()
	return fmt.Sprintf("hello %s; 2+3=%d; uuid=%s", name, mathx.Add(2, 3), id)
}
