// Fixture: exercises buildGodynModule's version-parity ldflags assembly —
// version.env auto-read (-X main.version), -X main.commit, and the structured
// ldflagsX convenience (-X main.channel). The flake check asserts the output.
package main

import "fmt"

var (
	version = "unset"
	commit  = "unset"
	channel = "unset"
)

func main() {
	fmt.Printf("version=%s commit=%s channel=%s\n", version, commit, channel)
}
